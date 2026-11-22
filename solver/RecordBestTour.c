#include "Solver.h"

/*
 * The RecordBestTour function records the current best tour in the BestTour 
 * array. 
 *
 * The function is called by Solvermain each time a run has resulted in a
 * shorter tour. Thus, when the predetermined number of runs have been
 * completed, BestTour contains an array representation of the best tour
 * found.    
 */

void RecordBestTour()
{
    int i;

    for (i = 0; i <= DimensionSaved; i++)
        BestTour[i] = BetterTour[i];
}
