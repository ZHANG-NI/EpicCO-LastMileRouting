#ifndef _HEAP_H
#define _HEAP_H

/* 
 * This header specifies the interface for the use of heaps. 
 */

#include "Solver.h"

void HeapMake(int Size);
void HeapInsert(Node * N);
void HeapClear(void);
void HeapDelete(Node * N);
Node *HeapDeleteMin(void);
void HeapLazyInsert(Node * N);
void Heapify(void);
void HeapSiftUp(Node * N);
void HeapSiftDown(Node * N);

#endif
