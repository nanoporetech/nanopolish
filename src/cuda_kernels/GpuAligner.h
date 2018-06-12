//
// Created by mike on 05/06/18.
//
#include <vector>
#include "nanopolish_variant.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <inttypes.h>
#include <assert.h>
#include <math.h>
#include <sys/time.h>
#include <algorithm>
#include <queue>
#include <sstream>
#include <fstream>
#include <set>
#include <omp.h>
#include <getopt.h>
#include <iterator>
#include "htslib/faidx.h"
#include "nanopolish_poremodel.h"
#include "nanopolish_transition_parameters.h"
#include "nanopolish_matrix.h"
#include "nanopolish_klcs.h"
#include "nanopolish_profile_hmm.h"
#include "nanopolish_alignment_db.h"
#include "nanopolish_anchor.h"
#include "nanopolish_variant.h"
#include "nanopolish_haplotype.h"
#include "nanopolish_pore_model_set.h"
#include "nanopolish_duration_model.h"
#include "nanopolish_variant_db.h"
#include "profiler.h"
#include "progress.h"
#include "stdaln.h"
#include <chrono>

#ifndef GPU_ALIGNER_H
#define GPU_ALIGNER_H1

class GpuAligner
{
public:
    int n[20];
    int y;
    int asize;

    GpuAligner();
    int calculateSum();
    void setY(int);

    std::vector<double>
    variantScoresThresholded(std::vector<Variant> tmp_variants, Haplotype haplotype, std::vector<HMMInputData> event_sequences,
              uint32_t alignment_flags, int screen_score_threshold, std::vector<std::string> methylation_types);// {
        //return std::vector<double>();
    //}
};
#endif // GPU_ALIGNER_H