#include <iostream>
#include <cuda.h>
#include "GpuAligner.h"
#include <vector>
#include "nanopolish_profile_hmm_r9.h"

#define MAX_STATES 256

#define EXPAND_TO_STRING(X) #X
#define TO_STRING(X) EXPAND_TO_STRING(X)
#define CU_CHECK_ERR(X) if (X != cudaSuccess){printf("CUDA error: <<%s>> at line %s\n", cudaGetErrorString(X), TO_STRING(__LINE__));throw std::runtime_error("CUDA ERROR");}

//#define move_down(curr_band) make_int2(curr_band.x + 1, curr_band.y)
//#define move_right(curr_band) make_int2(curr_band.x, curr_band.y + 1)



__device__ float logsumexpf(float x, float y){
    if(x == -INFINITY && y == -INFINITY){
        return -INFINITY;
    }
    float result = fmax(x, y) + log1pf(expf(-fabsf(y - x)));
    return result;
}

__device__ float lp_match_r9(int rank,
                             float mean,
                             float pore_mean,
                             float pore_stdv,
                             float pore_log_level_stdv,
                             float scale,
                             float shift,
                             float var,
                             float logVar){

    float log_inv_sqrt_2pi = logf(0.3989422804014327);

    float level = mean;
    float gaussian_mean = scale * pore_mean + shift;
    float gaussian_stdv = pore_stdv * var;
    float gaussian_log_level_stdv = pore_log_level_stdv + logVar;

    float a = (level - gaussian_mean) / gaussian_stdv;
    float emission = log_inv_sqrt_2pi - gaussian_log_level_stdv + (-0.5f * a * a);
    return emission;

}

__global__ void getScoresMod (float * poreModelDev,
                              int * readLengthsDev,
                              int * eventStartsDev,
                              int * eventStridesDev,
                              float * eventsPerBaseDev,
                              float * scaleDev,
                              float * shiftDev,
                              float * varDev,
                              float * logVarDev,
                              int * eventOffsetsDev,
                              float * eventMeansDev,
                              float * preFlankingDev,
                              float * postFlankingDev,
                              int * sequenceLengthsDev,
                              int * sequenceOffsetsDev,
                              int * kmerRanksDev,
                              int * seqIdxDev,
                              int * readIdxDev,
                              int numScores,
                              float * returnValuesDev){

    bool debug = false;
    if ((threadIdx.x == 0) && (blockIdx.x == 0)){
        debug = false;
    }

    // get buffer indices
    int scoreIdx = blockIdx.x * blockDim.x + threadIdx.x;

    if (scoreIdx < numScores) {

        int readIdx = readIdxDev[scoreIdx];
        int seqIdx = seqIdxDev[scoreIdx];

        // get read statistics
        int numEvents = readLengthsDev[readIdx];
        int readOffset = eventOffsetsDev[readIdx];
        float read_events_per_base = eventsPerBaseDev[readIdx];
        int e_start = eventStartsDev[readIdx]; // Event start for read
        int e_stride = eventStridesDev[readIdx];
        int e_offset = eventOffsetsDev[readIdx]; // Within the event means etc, the offset needed for this block to get a specific event
        float scale = scaleDev[readIdx];
        float shift = shiftDev[readIdx];
        float var = varDev[readIdx];
        float logVar = logVarDev[readIdx];

        // get sequence statistics
        int numKmers = sequenceLengthsDev[seqIdx];
        int seqOffset = sequenceOffsetsDev[seqIdx];

        int lastRowIdx = numEvents - 1;
        int lastKmerIdx = numKmers - 1;

        float returnValue = -INFINITY; //Used to sum over the last column.
        float prevProbabilities[MAX_STATES];

        int numBlocks = numKmers + 2;
        int numStates = numBlocks * PSR9_NUM_STATES; // 3 blocks per kmer and then 3 each for start and end state.

        if (debug) {
            printf("Kernel 1 >>> Num Kmers is %i\n", numKmers);
            printf("Kernel 1 >>> n_states %i\n", numStates);
            printf("Kernel 1 >>> num events in read is  %i\n", numEvents);
            printf("Kernel 1 >>> event offset is  %i\n", e_offset);
        }

        // Initialise the prev probabilities vector
        for (int i = 0; i < numStates - PSR9_NUM_STATES; i++) {
            prevProbabilities[i] = -INFINITY;
        }
        for (int i = numStates - PSR9_NUM_STATES; i < numStates; i++) {
            prevProbabilities[i] = 0.0f;
        }

        bool rc = false;
        if (e_stride == -1) {
            rc = true;
        }

        float p_stay = 1 - (1 / read_events_per_base);
        float p_skip = 0.0025;
        float p_bad = 0.001;
        float p_bad_self = p_bad;
        float p_skip_self = 0.3;
        float p_mk = p_skip; // probability of not observing an event at all
        float p_mb = p_bad; // probabilty of observing a bad event
        float p_mm_self = p_stay; // probability of observing additional events from this k-mer
        float p_mm_next = 1.0f - p_mm_self - p_mk - p_mb; // normal movement from state to state
        // transitions from event split state in previous block
        float p_bb = p_bad_self;
        float p_bk, p_bm_next, p_bm_self;
        p_bk = p_bm_next = p_bm_self = (1.0f - p_bb) / 3;
        // transitions from kmer skip state in previous block
        float p_kk = p_skip_self;
        float p_km = 1.0f - p_kk;
        // We assign some transition probabilities. I believe this is correct and they don't vary by location in the sequence
        float lp_mk = logf(p_mk);
        float lp_mb = logf(p_mb);
        float lp_mm_self = logf(p_mm_self);
        float lp_mm_next = logf(p_mm_next);
        float lp_bb = logf(p_bb);
        float lp_bk = logf(p_bk);
        float lp_bm_next = logf(p_bm_next);
        float lp_bm_self = logf(p_bm_self);
        float lp_kk = logf(p_kk);
        float lp_km = logf(p_km);
        float lp_sm, lp_ms;
        lp_sm = lp_ms = 0.0f;

        // the penalty is controlled by the transition probability
        float BAD_EVENT_PENALTY = 0.0f;

        //Fill out the dynamic programming table
        for (int row = 1; row < numEvents + 1; row++) {//TODO: check that numRows is correct value.
            //row-specific values
            int event_idx = e_start + (row - 1) * e_stride;
            float eventMean = eventMeansDev[e_offset + row - 1];
            float preFlank = preFlankingDev[e_offset + row - 1];
            float postFlank = postFlankingDev[e_offset + row - 1];

            float lp_emission_b = BAD_EVENT_PENALTY; //TODO: Can this be taken out of the inner loop?

            //Initialise temp registers
            float prevMatch = prevProbabilities[PSR9_MATCH];;
            float prevSkip = prevProbabilities[PSR9_KMER_SKIP];
            float prevBad = prevProbabilities[PSR9_BAD_EVENT];

            for (int blkIdx = 1; blkIdx < numBlocks - 1; blkIdx++) {
                int curBlockIdx = blkIdx;
                int prevBlockIdx = curBlockIdx - 1;
                int prevBlockOffset = PSR9_NUM_STATES * prevBlockIdx;
                int curBlockOffset = PSR9_NUM_STATES * curBlockIdx;

                int kmerIdx = blkIdx - 1; // because there is a start block with no associated kmer
                uint32_t rank = kmerRanksDev[seqOffset + kmerIdx + (numKmers *
                                                                    rc)]; // TODO understand why this is segfaulting sometimes, why does kmerIdx sometimes exceed 4096

                float pore_mean = poreModelDev[rank * 3];
                float pore_stdv = poreModelDev[rank * 3 + 1];
                float pore_log_level_stdv = poreModelDev[rank * 3 + 2];

                float lp_emission_m = lp_match_r9(rank,
                                                  eventMean,
                                                  pore_mean,
                                                  pore_stdv,
                                                  pore_log_level_stdv,
                                                  scale,
                                                  shift,
                                                  var,
                                                  logVar);

                // Get all the scores for a match
                float curMatch = prevProbabilities[curBlockOffset + PSR9_MATCH];
                float curBad = prevProbabilities[curBlockOffset + PSR9_BAD_EVENT];
                float curSkip = prevProbabilities[curBlockOffset + PSR9_KMER_SKIP];

                float HMT_FROM_SAME_M = lp_mm_self + curMatch;
                float HMT_FROM_PREV_M = lp_mm_next + prevMatch;
                float HMT_FROM_SAME_B = lp_bm_self + curBad;
                float HMT_FROM_PREV_B = lp_bm_next + prevBad;
                float HMT_FROM_PREV_K = lp_km + prevSkip;

                // m_s is the probability of going from the start state
                // to this kmer. The start state is (currently) only
                // allowed to go to the first kmer. If ALLOW_PRE_CLIP
                // is defined, we allow all events before this one to be skipped,
                // with a penalty;
                float HMT_FROM_SOFT = (kmerIdx == 0 &&
                                       (event_idx == e_start ||
                                        (HAF_ALLOW_PRE_CLIP))) ? lp_sm + preFlank : -INFINITY;

                // calculate the score
                float sum = HMT_FROM_SAME_M;
                sum = logsumexpf(sum, HMT_FROM_SOFT);
                sum = logsumexpf(sum, HMT_FROM_PREV_M);
                sum = logsumexpf(sum, HMT_FROM_SAME_B);
                sum = logsumexpf(sum, HMT_FROM_PREV_B);
                sum = logsumexpf(sum, HMT_FROM_PREV_K);
                sum += lp_emission_m;

                float newMatchScore = sum;

                // Calculate the bad event scores
                // state PSR9_BAD_EVENT
                HMT_FROM_SAME_M = lp_mb + curMatch;
                HMT_FROM_PREV_M = -INFINITY;
                HMT_FROM_SAME_B = lp_bb + prevBad;
                HMT_FROM_PREV_B = -INFINITY;
                HMT_FROM_PREV_K = -INFINITY;
                HMT_FROM_SOFT = -INFINITY;

                sum = HMT_FROM_SAME_M;
                sum = logsumexpf(sum, HMT_FROM_SAME_B);
                sum += lp_emission_b;

                float newBadEventScore = sum;

                // Write row out. prevProbabilities now becomes "current probabilities" for evaluating skips.
                prevProbabilities[curBlockOffset + PSR9_MATCH] = newMatchScore;
                prevProbabilities[curBlockOffset + PSR9_BAD_EVENT] = newBadEventScore;

                //Update tmp vars
                prevMatch = curMatch;
                prevSkip = curSkip;
                prevBad = prevBad;

                //Now do the non-skip-skip transition. This relies on the updated vector values.
                // state PSR9_KMER_SKIP
                HMT_FROM_PREV_M = lp_mk + prevProbabilities[prevBlockOffset + PSR9_MATCH];
                HMT_FROM_PREV_B = lp_bk + prevProbabilities[prevBlockOffset + PSR9_BAD_EVENT];
                HMT_FROM_PREV_K = lp_kk + prevProbabilities[prevBlockOffset + PSR9_KMER_SKIP];

                sum = HMT_FROM_PREV_M;
                sum = logsumexpf(sum, HMT_FROM_PREV_B);
                sum = logsumexpf(sum,
                                 HMT_FROM_PREV_K); //TODO - this is in the 'normal' kernel instead of HMT_FROM_PREV_M - is it wrong?
                sum = logsumexpf(sum,
                                 HMT_FROM_PREV_M); //TODO - assume this should probably be in there, but not in current

                float newSkipScore = sum;

                prevProbabilities[curBlockOffset + PSR9_KMER_SKIP] = newSkipScore;

                //post-clip transition
                if (kmerIdx == lastKmerIdx && ((HAF_ALLOW_POST_CLIP) || row == lastRowIdx)) {
                    float lp1 = lp_ms + prevProbabilities[curBlockOffset + PSR9_MATCH] + postFlank;
                    float lp2 = lp_ms + prevProbabilities[curBlockOffset + PSR9_BAD_EVENT] + postFlank;
                    float lp3 = lp_ms + prevProbabilities[curBlockOffset + PSR9_KMER_SKIP] + postFlank;

                    float end = returnValue;
                    end = logsumexpf(end, lp1);
                    end = logsumexpf(end, lp2);
                    end = logsumexpf(end, lp3);
                    returnValue = end;
                }
            }
        }
        returnValuesDev[scoreIdx] = returnValue;
    }
}


GpuAligner::GpuAligner()
{
    size_t numModelElements = 4096;
    size_t max_reads_per_worker = LOCI_PER_WORKER * MAX_COVERAGE * MAX_NUM_VARIANTS_PER_LOCUS;
    int readsSizeBuffer = max_reads_per_worker * sizeof(int);
    int maxBuffer = max_reads_per_worker * MAX_SEQUENCE_LENGTH * sizeof(int);

    //OLD
    int max_num_sequences = 1; //TODO can get rid of this
    int max_sequence_length = 100;
    int max_n_rows = 100;

    poreModelInitialized = false;

    CU_CHECK_ERR(cudaMalloc((void**)&scaleDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&scaleHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&shiftDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&shiftHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&varDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&varHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&logVarDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&logVarHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&readLengthsDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&readLengthsHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventsPerBaseDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventsPerBaseHost, maxBuffer, cudaHostAllocDefault));

    // Allocate Device memory for pore model
    CU_CHECK_ERR(cudaMalloc((void**)&poreModelDev, numModelElements * 3 * sizeof(float)));
    CU_CHECK_ERR(cudaHostAlloc(&poreModelHost, numModelElements * sizeof(float) * 3, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventStartsDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventStartsHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventStridesDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventStridesHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventOffsetsDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventOffsetsHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventMeansDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventMeans, maxBuffer , cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&preFlankingDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&preFlankingHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&postFlankingDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&postFlankingHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&sequenceOffsetsDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&sequenceOffsetsHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&sequenceLengthsDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&sequenceLengthsHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&scoresDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&returnValuesHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&seqIdxDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&seqIdxHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&readIdxDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&readIdxHost, maxBuffer, cudaHostAllocDefault));

    int numKmers = max_sequence_length * max_num_sequences;
    CU_CHECK_ERR(cudaHostAlloc(&kmerRanks, maxBuffer , cudaHostAllocDefault));
    CU_CHECK_ERR(cudaMalloc((void**)&kmerRanksDev, maxBuffer ));

    // Allocate host memory for model
    returnValuesHostResultsPointers.resize(max_num_sequences);
    kmerRanksDevPointers.resize(max_num_sequences);
    returnValuesDevResultsPointers.resize(max_num_sequences);

    for (int i =0; i<max_num_sequences;i++){
        cudaStreamCreate(&streams[i]);
    }
}

//Destructor
GpuAligner::~GpuAligner() {
    CU_CHECK_ERR(cudaFree(scaleDev));
    CU_CHECK_ERR(cudaFree(shiftDev));
    CU_CHECK_ERR(cudaFree(varDev));
    CU_CHECK_ERR(cudaFree(logVarDev));
    CU_CHECK_ERR(cudaFree(eventsPerBaseDev));
    CU_CHECK_ERR(cudaFree(readLengthsDev));
    CU_CHECK_ERR(cudaFree(eventMeansDev));
    CU_CHECK_ERR(cudaFree(eventStartsDev));
    CU_CHECK_ERR(cudaFree(eventStridesDev));
    CU_CHECK_ERR(cudaFree(eventOffsetsDev));
    CU_CHECK_ERR(cudaFree(preFlankingDev));
    CU_CHECK_ERR(cudaFree(postFlankingDev));
    CU_CHECK_ERR(cudaFree(kmerRanksDev));
    CU_CHECK_ERR(cudaFree(poreModelDev));
    CU_CHECK_ERR(cudaFree(sequenceOffsetsDev));
    CU_CHECK_ERR(cudaFree(sequenceLengthsDev));
    CU_CHECK_ERR(cudaFree(scoresDev));
    CU_CHECK_ERR(cudaFree(seqIdxDev));
    CU_CHECK_ERR(cudaFree(readIdxDev));

    CU_CHECK_ERR(cudaFreeHost(eventMeans));
    CU_CHECK_ERR(cudaFreeHost(poreModelHost));
    CU_CHECK_ERR(cudaFreeHost(preFlankingHost));
    CU_CHECK_ERR(cudaFreeHost(postFlankingHost));
    CU_CHECK_ERR(cudaFreeHost(kmerRanks));
    CU_CHECK_ERR(cudaFreeHost(sequenceOffsetsHost));
    CU_CHECK_ERR(cudaFreeHost(returnValuesHost));
    CU_CHECK_ERR(cudaFreeHost(readLengthsHost));
    CU_CHECK_ERR(cudaFreeHost(sequenceLengthsHost));
    CU_CHECK_ERR(cudaFreeHost(seqIdxHost));
    CU_CHECK_ERR(cudaFreeHost(readIdxHost));

    int max_num_sequences = 1; //TODO can get rid of this
    for (int i =0; i<max_num_sequences; i++) {
      CU_CHECK_ERR(cudaStreamDestroy(streams[i]));
    }
}

std::vector<std::vector<std::vector<double>>> GpuAligner::scoreKernelMod(std::vector<ScoreSet> &scoreSets,
                                                                         uint32_t alignment_flags){

    int numEventsTotal = 0; // The number of events across all scoreSets
    int  numSequences = 0; // The number of sequences across all scoreSets
    int kmerOffset = 0;
    int numReads = 0; // The number of reads across all scoreSets
    int numScoreSets = scoreSets.size();

    int rawReadOffset = 0;
    int globalReadIdx = 0;
    int globalSequenceIdx = 0;
    int globalScoreIdx = 0;

    //Loop over every scoreset, filling out buffers and counters
    for (int scoreSetIdx=0; scoreSetIdx < numScoreSets; scoreSetIdx++){
        auto scoreSet = scoreSets[scoreSetIdx];
        int firstReadIdxinScoreSet = globalReadIdx;
        //Read data
        for (int eventSequenceIdx=0; eventSequenceIdx < scoreSet.rawData.size();eventSequenceIdx++){
            auto e = scoreSet.rawData[eventSequenceIdx];
            numReads++;

            //Read statistics - populate host buffers
            scaleHost[globalReadIdx] = e.read->scalings[e.strand].scale;
            shiftHost[globalReadIdx] = e.read->scalings[e.strand].shift;
            varHost[globalReadIdx] = e.read->scalings[e.strand].var;
            logVarHost[globalReadIdx] = e.read->scalings[e.strand].log_var;

            int e_start = e.event_start_idx;
            eventStartsHost[globalReadIdx] = e_start;

            int e_stride = e.event_stride;
            eventStridesHost[globalReadIdx] = e_stride;

            uint32_t e_end = e.event_stop_idx;
            uint32_t n_events;
            if(e_end > e_start)
                n_events = e_end - e_start + 1;
            else
                n_events = e_start - e_end + 1;
            readLengthsHost[globalReadIdx] = n_events;
            numEventsTotal += n_events;

            eventOffsetsHost[globalReadIdx] = rawReadOffset;

            float readEventsPerBase = e.read->events_per_base[e.strand];
            eventsPerBaseHost[globalReadIdx] = readEventsPerBase;

            std::vector<float> pre_flank = make_pre_flanking(e, e_start, n_events);
            std::vector<float> post_flank = make_post_flanking(e, e_start, n_events);

            for (int i=0;i<n_events;i++) {
                auto event_idx =  e_start + i * e_stride;
                auto scaled = e.read->get_drift_scaled_level(event_idx, e.strand); // send the data in drift scaled
                eventMeans[rawReadOffset + i] = scaled;

                //populate the pre/post-flanking data, since it has a 1-1 correspondence with events
                preFlankingHost[rawReadOffset + i] = pre_flank[i];
                postFlankingHost[rawReadOffset + i] = post_flank[i];
                }

            rawReadOffset += n_events;
            globalReadIdx++;
        }
        //Pore Model
        const uint32_t k = scoreSets[0].rawData[0].pore_model->k; //k is the length of a kmer in the pore model
        if (poreModelInitialized == false) {
            int num_states = scoreSets[0].rawData[0].pore_model->states.size();
            int poreModelEntriesPerState = 3;
            for(int st=0; st<num_states; st++){
                auto params = scoreSets[0].rawData[0].pore_model->states[st];
                poreModelHost[st * poreModelEntriesPerState] = params.level_mean;
                poreModelHost[st * poreModelEntriesPerState + 1] = params.level_stdv;
                poreModelHost[st * poreModelEntriesPerState + 2] = params.level_log_stdv;
            }
            // copy over the pore model
            CU_CHECK_ERR(cudaMemcpyAsync(poreModelDev, poreModelHost,
                            poreModelEntriesPerState * 4096 * sizeof(float), cudaMemcpyHostToDevice, streams[0])); // TODO don't hardcode num kmers
            poreModelInitialized = true;
        }
        // Sequences
        // Sequences
        auto & sequences = scoreSet.stateSequences;
        numSequences += sequences.size();

        for (int i = 0; i<sequences.size(); i++) {
            auto sequence = sequences[i];

            sequenceOffsetsHost[globalSequenceIdx] = kmerOffset;

            int sequenceLength = sequence.length();

            int numKmers = sequenceLength - k + 1;

            for(size_t ki = 0; ki < numKmers; ++ki) {
                int rank = sequence.get_kmer_rank(ki, k, false);
                kmerRanks[ki + kmerOffset] = rank;
            }
            //kmerRanksDevPointers[i] = kmerRanksDev + kmerOffset;
            kmerOffset += numKmers;

            for(size_t ki = 0; ki < numKmers; ++ki) {
                int rank = sequence.get_kmer_rank(ki, k, true);
                kmerRanks[ki + kmerOffset] = rank;
            }

            kmerOffset += numKmers;

            sequenceLengthsHost[globalSequenceIdx] = numKmers;

            // Loop over the raw reads, producing a cartesian product of the two

            auto numReadsInScoreSet = scoreSet.rawData.size();
            for (int r=0; r<numReadsInScoreSet; r++){
                seqIdxHost[globalScoreIdx] = globalSequenceIdx;
                readIdxHost[globalScoreIdx] = firstReadIdxinScoreSet + r;
                globalScoreIdx++;
            }

            globalSequenceIdx++;
            }
    }

    // All data is now in host buffers - perform memcpys
    //Read statistics
    CU_CHECK_ERR(cudaMemcpyAsync(eventStartsDev, eventStartsHost,
                    numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(eventsPerBaseDev, eventsPerBaseHost,
                    numReads * sizeof(float), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(scaleDev, scaleHost,
                    numReads * sizeof(float), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(shiftDev, shiftHost,
                    numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(eventStridesDev, eventStridesHost,
                                 numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(varDev, varHost,
                    numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(logVarDev, logVarHost,
                    numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    CU_CHECK_ERR(cudaMemcpyAsync(readLengthsDev, readLengthsHost,
                                 numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    // Read offsets
    CU_CHECK_ERR(cudaMemcpyAsync(eventOffsetsDev, eventOffsetsHost,
                    numReads * sizeof(int), cudaMemcpyHostToDevice, streams[0]));

    // Reads + Flanks
    CU_CHECK_ERR(cudaMemcpyAsync(eventMeansDev, eventMeans, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice, streams[0] ));

    CU_CHECK_ERR(cudaMemcpyAsync(preFlankingDev, preFlankingHost, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice, streams[0] ));

    CU_CHECK_ERR(cudaMemcpyAsync(postFlankingDev, postFlankingHost, numEventsTotal * sizeof(float), cudaMemcpyHostToDevice, streams[0] ));

    // Sequence statistics

    CU_CHECK_ERR(cudaMemcpyAsync(sequenceLengthsDev, sequenceLengthsHost, numSequences * sizeof(int), cudaMemcpyHostToDevice, streams[0] ));

    // Sequence offsets
    CU_CHECK_ERR(cudaMemcpyAsync(sequenceOffsetsDev, sequenceOffsetsHost, numSequences * sizeof(int), cudaMemcpyHostToDevice, streams[0] ));

    // Sequences
    CU_CHECK_ERR(cudaMemcpyAsync(kmerRanksDev, kmerRanks, kmerOffset * sizeof(int), cudaMemcpyHostToDevice, streams[0] ));

    // Job details
    CU_CHECK_ERR(cudaMemcpyAsync(seqIdxDev, seqIdxHost, globalScoreIdx * sizeof(int), cudaMemcpyHostToDevice, streams[0] ));
    CU_CHECK_ERR(cudaMemcpyAsync(readIdxDev, readIdxHost, globalScoreIdx * sizeof(int), cudaMemcpyHostToDevice, streams[0] ));

    // Launch Kernels

    int blockSize = 32;
    int numBlocks =  (globalScoreIdx + blockSize - 1 ) / blockSize;
    dim3 dimBlock(blockSize);
    dim3 dimGrid(numBlocks);

    getScoresMod <<< dimGrid, dimBlock, 0, streams[0]>>> (poreModelDev,
                                                          readLengthsDev,
                                                          eventStartsDev,
                                                          eventStridesDev,
                                                          eventsPerBaseDev,
                                                          scaleDev,
                                                          shiftDev,
                                                          varDev,
                                                          logVarDev,
                                                          eventOffsetsDev,
                                                          eventMeansDev,
                                                          preFlankingDev,
                                                          postFlankingDev,
                                                          sequenceLengthsDev,
                                                          sequenceOffsetsDev,
                                                          kmerRanksDev,
                                                          seqIdxDev,
                                                          readIdxDev,
                                                          globalScoreIdx,
                                                          scoresDev);
    cudaError_t err = cudaGetLastError();

    if (err != cudaSuccess)
        printf("Errors during kernel execution: %s\n", cudaGetErrorString(err));

    cudaMemcpyAsync(returnValuesHost, scoresDev,
                    globalScoreIdx * sizeof(float), cudaMemcpyDeviceToHost, streams[0]);
    cudaStreamSynchronize(streams[0]);

    //Unpack results
    int k = 0;
    std::vector<std::vector<std::vector<double>>> result(scoreSets.size());

    for(int scoreSetIdx=0; scoreSetIdx<numScoreSets; scoreSetIdx++){
        auto scoreSet = scoreSets[scoreSetIdx];
        int numSequences = scoreSet.stateSequences.size();
        int numReads = scoreSet.rawData.size();
        for (int seqIdx=0; seqIdx<numSequences; seqIdx++){

            std::vector<double> seqScores(numReads);

            for (int readIdx=0; readIdx<numReads; readIdx++){
                float score = returnValuesHost[k];
                seqScores[readIdx] = score;
                k++;
            }
            result[scoreSetIdx].push_back(seqScores);
        }
    }

    return result;
}


std::vector<Variant> GpuAligner::variantScoresThresholded(std::vector<std::vector<Variant>> input_variants_vector,
                                                          std::vector<Haplotype> base_haplotypes,
                                                          std::vector<std::vector<HMMInputData>> event_sequences_vector,
                                                          uint32_t alignment_flags,
                                                          int screen_score_threshold,
                                                          std::vector<std::string> methylation_types) {
  int numScoreSets = base_haplotypes.size();
  std::vector<ScoreSet> scoreSets;
  scoreSets.resize(numScoreSets);

  for(int scoreSetIdx=0; scoreSetIdx<numScoreSets;scoreSetIdx++){

    auto input_variants = input_variants_vector[scoreSetIdx];
    auto base_haplotype = base_haplotypes[scoreSetIdx];
    auto event_sequences = event_sequences_vector[scoreSetIdx];

    if (event_sequences.size() > MAX_COVERAGE) {
        event_sequences.resize(MAX_COVERAGE);
    }

    int numVariants = input_variants.size();

    std::vector<Variant> out_variants = input_variants;
    std::vector<Haplotype> variant_haplotypes(numVariants, base_haplotype);

    //loop over the vector, applying the variants to the haplotypes
    for (int i = 0; i<input_variants.size();i++){
        variant_haplotypes[i].apply_variant(input_variants[i]);
    }

    // Make methylated versions of each input sequence. Once for the base haplotype and once each for each variant

    std::vector<HMMInputSequence> sequences;

    HMMInputSequence base_sequence = generate_methylated_alternatives(base_haplotype.get_sequence(),
                                                                                    methylation_types)[0]; //TODO: fix for non-zero

    sequences.push_back(base_sequence);

    for (auto v: variant_haplotypes){
        auto variant_sequence = generate_methylated_alternatives(v.get_sequence(), methylation_types)[0];  //TODO: fix for non-zero
        sequences.push_back(variant_sequence);
    }

    ScoreSet s = {
      sequences,
      event_sequences
    };

    scoreSets[scoreSetIdx] = s;

  }

  std::vector<Variant> v;
  if (!event_sequences_vector.empty()) {
    //std::vector<std::vector<double>> scores = scoreKernel(sequences, event_sequences, alignment_flags);

    auto scoresMod = scoreKernelMod(scoreSets, alignment_flags);

    // results are now ready, need to unpack them
    for (int scoreSetIdx=0; scoreSetIdx<numScoreSets; scoreSetIdx++){
      std::vector<std::vector<double>> scores = scoresMod[scoreSetIdx]; // scores for this candidate, including all variants and base(zeroth)
      int numVariants = scores.size() - 1; // subtract one for the base
      int numScores = scores[0].size();

      for (int variantIndex = 0; variantIndex < numVariants; variantIndex++) { // index 0 is the base scores
	double totalScore = 0.0;
	for (int k = 0; k < numScores; k++) {
	  if (fabs(totalScore) < screen_score_threshold) {
	    double baseScore = scores[0][k];
	    totalScore += (scores[variantIndex + 1][k] - baseScore);
	  }
	}
	// get the old variant:
	auto unScoredVariant = input_variants_vector[scoreSetIdx][variantIndex];
	unScoredVariant.quality = totalScore;
	unScoredVariant.info = "";
	v.push_back(unScoredVariant);
      }
    }
  }
  return v;
}

GpuAdaptiveBandedAligner::GpuAdaptiveBandedAligner(){
    size_t max_reads_per_worker = LOCI_PER_WORKER * MAX_COVERAGE * MAX_NUM_VARIANTS_PER_LOCUS;
    int readsSizeBuffer = max_reads_per_worker * sizeof(int);
    int maxBuffer = max_reads_per_worker * MAX_SEQUENCE_LENGTH * sizeof(int);
    size_t numModelElements = 4096;

    // Need to allocate memory for the DP tables
    int max_n_bands = (ADAPTIVE_ALIGNMENT_MAX_N_EVENTS + 1) + (ADAPTIVE_ALIGNMENT_MAX_N_KMERS + 1);
    int max_band_buffer_size = ADAPTIVE_ALIGNMENT_MAX_NUM_READS * max_n_bands * ADAPTIVE_ALIGNMENT_BANDWIDTH * sizeof(float);

    //allocate a buffer to hold the number of events per read
    CU_CHECK_ERR(cudaMalloc((void**)&nEventsDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&nEventsHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&nKmersDev, readsSizeBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&nKmersHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&kmersDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&kmersHost, maxBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&eventsDev, maxBuffer));
    CU_CHECK_ERR(cudaHostAlloc(&eventsHost, readsSizeBuffer, cudaHostAllocDefault));

    CU_CHECK_ERR(cudaMalloc((void**)&traceBuffer, max_band_buffer_size));
    CU_CHECK_ERR(cudaMalloc((void**)&bandScoreBuffer, max_band_buffer_size));


    CU_CHECK_ERR(cudaMalloc((void**)&lowerLeftBuffer, ADAPTIVE_ALIGNMENT_MAX_NUM_READS * max_n_bands * 2 * sizeof(int)));
}

GpuAdaptiveBandedAligner::~GpuAdaptiveBandedAligner(){
    CU_CHECK_ERR(cudaFree(nEventsDev));
    CU_CHECK_ERR(cudaFree(eventsDev));
    CU_CHECK_ERR(cudaFree(nKmersDev));
    CU_CHECK_ERR(cudaFree(kmersDev));
    CU_CHECK_ERR(cudaFree(bandScoreBuffer));
    CU_CHECK_ERR(cudaFree(traceBuffer));
    CU_CHECK_ERR(cudaFree(lowerLeftBuffer));

    CU_CHECK_ERR(cudaFreeHost(nEventsHost));
    CU_CHECK_ERR(cudaFreeHost(nKmersHost));
    CU_CHECK_ERR(cudaFreeHost(kmersHost));
    //CU_CHECK_ERR(cudaFree(eventsHost));
}

//TODO double-check all of these
#define move_down(curr_band) make_int2((curr_band).x + 1, (curr_band).y)
#define move_right(curr_band) make_int2((curr_band).x, (curr_band).y + 1)
#define band_kmer_to_offset(bi, ki) (ki) - lowerLeftBuffer[(blockDim.x * (bi) + threadIdx.x)].y
#define band_event_to_offset(bi, ei) lowerLeftBuffer[(bi)].x - (ei)
#define band_offset(band_idx) (((band_idx) * blockDim.x + threadIdx.x) * ADAPTIVE_ALIGNMENT_BANDWIDTH)
#define is_offset_valid(offset) (offset) >= 0 && (offset) < ADAPTIVE_ALIGNMENT_BANDWIDTH
#define event_at_offset(bi, offset) lowerLeftBuffer[(bi) * blockIdx.x + threadIdx.x].x - (offset)

__global__ void adaptiveBandedAlign(float* bandScoreBuffer,
                                    int* traceBuffer,
                                    int numReads,
                                    int * nKmersDev,
                                    int * kmersDev,
				                    int * nEventsDev,
                                    float * eventsDev,
                                    int2* lowerLeftBuffer)
{
  int n_kmers = nKmersDev[threadIdx.x];
  int n_events = nEventsDev[threadIdx.x];

  // backtrack markers
    const uint8_t from_d = 0;
    const uint8_t from_u = 1;
    const uint8_t from_l = 2;

    float min_average_log_emission = -5.0;
  int max_gap_threshold = 50;

  // banding
  int half_bandwidth = ADAPTIVE_ALIGNMENT_BANDWIDTH / 2;

  // transition penalties
  float events_per_kmer = n_events / n_kmers;
  float p_stay = 1 - (1 / (events_per_kmer + 1));

  // setting a tiny skip penalty helps keep the true alignment within the adaptive band
  // this was empirically determined
  double epsilon = 1e-10;
  double lp_skip = log(epsilon);
  double lp_stay = log(p_stay);
  double lp_step = log(1.0 - exp(lp_skip) - exp(lp_stay));
  double lp_trim = log(0.01);
 
  // dp matrix
  int n_rows = n_events + 1;
  int n_cols = n_kmers + 1;
  int n_bands = n_rows + n_cols;

    // Initialize the DP tables. Band-major, interleaved. -- is this correct
    // Is this what is taking so long?
    for(int band_idx = 0; band_idx<n_bands; band_idx++){
        for(int b=0; b<ADAPTIVE_ALIGNMENT_BANDWIDTH; b++){
            bandScoreBuffer[(band_idx * blockDim.x + threadIdx.x) * ADAPTIVE_ALIGNMENT_BANDWIDTH + b] = -INFINITY;
            traceBuffer[(band_idx * blockDim.x + threadIdx.x) * ADAPTIVE_ALIGNMENT_BANDWIDTH + b] = 0;
        }
    }

    // initialize range of first two bands
    lowerLeftBuffer[threadIdx.x].x = half_bandwidth - 1; // x is eventIdx
    lowerLeftBuffer[threadIdx.y].y = -1 - half_bandwidth; // y is kmerIdx
    lowerLeftBuffer[blockDim.x + 1 + threadIdx.x] = move_down(lowerLeftBuffer[threadIdx.x]);

    // Set first band central cell to zero:
    int start_cell_offset = band_kmer_to_offset(0, -1);
    bandScoreBuffer[ADAPTIVE_ALIGNMENT_BANDWIDTH * threadIdx.x + start_cell_offset] = 0.0f;

    // band 1: first event is trimmed
    int first_trim_offset = band_event_to_offset(threadIdx.x + 1 * blockDim.x, 0);
    bandScoreBuffer[(blockDim.x + threadIdx.x) * ADAPTIVE_ALIGNMENT_BANDWIDTH + first_trim_offset] = lp_trim;
    traceBuffer[(blockDim.x + threadIdx.x) * ADAPTIVE_ALIGNMENT_BANDWIDTH + first_trim_offset] = from_u;

    int fills = 0;
    //Fill in remaining bands..

    for(int band_idx = 2; band_idx < n_bands; ++band_idx) {
        // Determine placement of this band according to Suzuki's adaptive algorithm
        // When both ll and ur are out-of-band (ob) we alternate movements
        // otherwise we decide based on scores

        int llIdx = band_offset(band_idx - 1);
        float ll = bandScoreBuffer[llIdx];
        int urIdx = band_offset(band_idx - 1) + ADAPTIVE_ALIGNMENT_BANDWIDTH -1;
        float ur = bandScoreBuffer[urIdx];

        bool ll_ob = ll == -INFINITY;
        bool ur_ob = ur == -INFINITY;

        bool right = false;
        if(ll_ob && ur_ob) {
            right = band_idx % 2 == 1;
        } else {
            right = ll < ur; // Suzuki's rule
        }

        if(right) {
            auto newPos = move_right(lowerLeftBuffer[blockDim.x * (band_idx - 1) + threadIdx.x]);
            lowerLeftBuffer[blockDim.x * band_idx + threadIdx.x] = newPos;
        } else {
            lowerLeftBuffer[blockDim.x * band_idx + threadIdx.x] = move_down(lowerLeftBuffer[blockDim.x * (band_idx - 1) + threadIdx.x]);
        }

        // If the trim state is within the band, fill it in here
        int trim_offset = band_kmer_to_offset(band_idx, -1);
        if(is_offset_valid(trim_offset)) {
            int event_idx = event_at_offset(band_idx, trim_offset);
            if(event_idx >= 0 && event_idx < n_events) {
                bandScoreBuffer[band_offset(band_idx) + trim_offset] = lp_trim * (event_idx + 1);
                traceBuffer[band_offset(band_idx) + trim_offset] = from_u;
            } else {
                bandScoreBuffer[band_offset(band_idx) + trim_offset] = -INFINITY;
            }
        }
    }//BAND-FILL END
}

std::vector<std::vector<AlignedPair>> GpuAdaptiveBandedAligner::align(std::vector<SquiggleRead *> reads, const PoreModel *pore_model) {
    size_t numReads = reads.size();
    size_t strand_idx = 0;
    size_t k = pore_model->k;
    const Alphabet* alphabet = pore_model->pmalphabet;

    //Loop over all the reads, populating host buffers with the relevant information
    int kmersOffset = 0;
    for (int readIdx=0; readIdx < numReads; readIdx++) {//switch to index
        // Populate host buffer with kmer ranks
        auto read = reads[readIdx];
        auto sequence = read->read_sequence;
        size_t n_kmers = sequence.size() - k + 1;
	    size_t n_events = read->events->size(); //read->events.size();
        for(int kmerIdx=0; kmerIdx<n_kmers;kmerIdx++){
	  kmersHost[kmerIdx + kmersOffset] = alphabet->kmer_rank(sequence.substr(kmerIdx, k).c_str(), k);
        }
	//TODO: Will also need to transfer the offsets.
        kmersOffset += n_kmers;
        nKmersHost[readIdx] = n_kmers;
	nEventsHost[readIdx] = n_events;
    }

  
   // do the transfers
    CU_CHECK_ERR(cudaMemcpyAsync(nKmersDev, nKmersHost, numReads * sizeof(int), cudaMemcpyHostToDevice));
    CU_CHECK_ERR(cudaMemcpyAsync(kmersDev, kmersHost, kmersOffset * sizeof(int), cudaMemcpyHostToDevice));
    CU_CHECK_ERR(cudaMemcpyAsync(nEventsDev, nEventsHost, numReads * sizeof(int), cudaMemcpyHostToDevice));

    // run the kernel
    size_t blockSize = numReads;
    size_t numBlocks = 1;
    dim3 dimBlock(blockSize);
    dim3 dimGrid(numBlocks);

    adaptiveBandedAlign <<<dimGrid, dimBlock, 0 >>> (bandScoreBuffer, traceBuffer, numReads, nKmersDev, kmersDev, nEventsDev, eventsDev, lowerLeftBuffer);

    return std::vector<std::vector<AlignedPair>>();
}
