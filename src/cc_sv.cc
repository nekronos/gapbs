// Copyright (c) 2015, The Regents of the University of California (Regents)
// See LICENSE.txt for license details

#include <algorithm>
#include <cinttypes>
#include <iostream>
#include <unordered_map>
#include <vector>

#include "benchmark.h"
#include "bitmap.h"
#include "builder.h"
#include "command_line.h"
#include "graph.h"
#include "pvector.h"


/*
GAP Benchmark Suite
Kernel: Connected Components (CC)
Author: Scott Beamer

Will return comp array labelling each vertex with a connected component ID

This CC implementation makes use of the Shiloach-Vishkin [2] algorithm with
implementation optimizations from Bader et al. [1]. Michael Sutton contributed
a fix for directed graphs using the min-max swap from [3], and it also produces
more consistent performance for undirected graphs.

[1] David A Bader, Guojing Cong, and John Feo. "On the architectural
    requirements for efficient execution of graph algorithms." International
    Conference on Parallel Processing, Jul 2005.

[2] Yossi Shiloach and Uzi Vishkin. "An o(logn) parallel connectivity algorithm"
    Journal of Algorithms, 3(1):57–67, 1982.

[3] Kishore Kothapalli, Jyothish Soman, and P. J. Narayanan. "Fast GPU
    algorithms for graph connectivity." Workshop on Large Scale Parallel
    Processing, 2010.
*/


using namespace std;

#ifndef PR_PREFETCH_DIST
#define PR_PREFETCH_DIST 0
#endif
#ifndef PR_PREFETCH_HINT
#define PR_PREFETCH_HINT 3
#endif
#ifndef PR_PREFETCH_FLAT
#define PR_PREFETCH_FLAT 0
#endif


// The hooking condition (comp_u < comp_v) may not coincide with the edge's
// direction, so we use a min-max swap such that lower component IDs propagate
// independent of the edge's direction.
pvector<NodeID> ShiloachVishkin(const Graph &g) {
  pvector<NodeID> comp(g.num_nodes());
  #pragma omp parallel for
  for (NodeID n=0; n < g.num_nodes(); n++)
    comp[n] = n;
  bool change = true;
  int num_iter = 0;
#if PR_PREFETCH_DIST > 0 && PR_PREFETCH_FLAT
  const NodeID *edge_end =
      g.num_nodes() > 0 ? g.out_neigh(g.num_nodes() - 1).end() : nullptr;
#endif
  while (change) {
    change = false;
    num_iter++;
    #pragma omp parallel for
    for (NodeID u=0; u < g.num_nodes(); u++) {
#if PR_PREFETCH_DIST > 0 && PR_PREFETCH_FLAT
      auto out_nb = g.out_neigh(u);
      const NodeID *last = out_nb.end();
      for (const NodeID *p = out_nb.begin(); p < last; p++) {
        // edge_end - p > D rather than p + D < edge_end: the latter forms a
        // pointer past the end of the array, which is undefined behaviour even
        // though it compiles to the same lea/cmp/cmov here.
        const NodeID *pf = (edge_end - p > PR_PREFETCH_DIST)
                               ? p + PR_PREFETCH_DIST
                               : edge_end - 1;
        __builtin_prefetch(&comp[*pf], 0, PR_PREFETCH_HINT);
        NodeID v = *p;
        NodeID comp_u = comp[u];
        NodeID comp_v = comp[v];
        if (comp_u == comp_v) continue;
        // Hooking condition so lower component ID wins independent of direction
        NodeID high_comp = comp_u > comp_v ? comp_u : comp_v;
        NodeID low_comp = comp_u + (comp_v - high_comp);
        if (high_comp == comp[high_comp]) {
          change = true;
          comp[high_comp] = low_comp;
        }
      }
#elif PR_PREFETCH_DIST > 0
      auto out_nb = g.out_neigh(u);
      const NodeID *first = out_nb.begin();
      const NodeID *last = out_nb.end();
      // Split the loop rather than clamping inside it: at average degree 15.7
      // against D>=32 a clamp to last-1 fires on essentially every vertex and
      // issues one redundant prefetch per edge (bc.cc measured -7.1% with the
      // clamp, +9.0% with the split). A list shorter than D issues none.
      // Only the first hop comp[v] is prefetchable: comp[high_comp] is
      // addressed by the value comp[v] returns, so it cannot be covered.
      const NodeID *main_end =
          (last - first > PR_PREFETCH_DIST) ? last - PR_PREFETCH_DIST : first;
      const NodeID *p = first;
      for (; p < main_end; p++) {
        __builtin_prefetch(&comp[*(p + PR_PREFETCH_DIST)], 0, PR_PREFETCH_HINT);
        NodeID v = *p;
        NodeID comp_u = comp[u];
        NodeID comp_v = comp[v];
        if (comp_u == comp_v) continue;
        // Hooking condition so lower component ID wins independent of direction
        NodeID high_comp = comp_u > comp_v ? comp_u : comp_v;
        NodeID low_comp = comp_u + (comp_v - high_comp);
        if (high_comp == comp[high_comp]) {
          change = true;
          comp[high_comp] = low_comp;
        }
      }
      for (; p < last; p++) {            // tail: no prefetch
        NodeID v = *p;
        NodeID comp_u = comp[u];
        NodeID comp_v = comp[v];
        if (comp_u == comp_v) continue;
        // Hooking condition so lower component ID wins independent of direction
        NodeID high_comp = comp_u > comp_v ? comp_u : comp_v;
        NodeID low_comp = comp_u + (comp_v - high_comp);
        if (high_comp == comp[high_comp]) {
          change = true;
          comp[high_comp] = low_comp;
        }
      }
#else
      for (NodeID v : g.out_neigh(u)) {
        NodeID comp_u = comp[u];
        NodeID comp_v = comp[v];
        if (comp_u == comp_v) continue;
        // Hooking condition so lower component ID wins independent of direction
        NodeID high_comp = comp_u > comp_v ? comp_u : comp_v;
        NodeID low_comp = comp_u + (comp_v - high_comp);
        if (high_comp == comp[high_comp]) {
          change = true;
          comp[high_comp] = low_comp;
        }
      }
#endif
    }
    #pragma omp parallel for
    for (NodeID n=0; n < g.num_nodes(); n++) {
      while (comp[n] != comp[comp[n]]) {
        comp[n] = comp[comp[n]];
      }
    }
  }
  cout << "Shiloach-Vishkin took " << num_iter << " iterations" << endl;
  return comp;
}


void PrintCompStats(const Graph &g, const pvector<NodeID> &comp) {
  cout << endl;
  unordered_map<NodeID, NodeID> count;
  for (NodeID comp_i : comp)
    count[comp_i] += 1;
  int k = 5;
  vector<pair<NodeID, NodeID>> count_vector;
  count_vector.reserve(count.size());
  for (auto kvp : count)
    count_vector.push_back(kvp);
  vector<pair<NodeID, NodeID>> top_k = TopK(count_vector, k);
  k = min(k, static_cast<int>(top_k.size()));
  cout << k << " biggest clusters" << endl;
  for (auto kvp : top_k)
    cout << kvp.second << ":" << kvp.first << endl;
  cout << "There are " << count.size() << " components" << endl;
}


// Verifies CC result by performing a BFS from a vertex in each component
// - Asserts search does not reach a vertex with a different component label
// - If the graph is directed, it performs the search as if it was undirected
// - Asserts every vertex is visited (degree-0 vertex should have own label)
bool CCVerifier(const Graph &g, const pvector<NodeID> &comp) {
  unordered_map<NodeID, NodeID> label_to_source;
  for (NodeID n : g.vertices())
    label_to_source[comp[n]] = n;
  Bitmap visited(g.num_nodes());
  visited.reset();
  vector<NodeID> frontier;
  frontier.reserve(g.num_nodes());
  for (auto label_source_pair : label_to_source) {
    NodeID curr_label = label_source_pair.first;
    NodeID source = label_source_pair.second;
    frontier.clear();
    frontier.push_back(source);
    visited.set_bit(source);
    for (auto it = frontier.begin(); it != frontier.end(); it++) {
      NodeID u = *it;
      for (NodeID v : g.out_neigh(u)) {
        if (comp[v] != curr_label)
          return false;
        if (!visited.get_bit(v)) {
          visited.set_bit(v);
          frontier.push_back(v);
        }
      }
      if (g.directed()) {
        for (NodeID v : g.in_neigh(u)) {
          if (comp[v] != curr_label)
            return false;
          if (!visited.get_bit(v)) {
            visited.set_bit(v);
            frontier.push_back(v);
          }
        }
      }
    }
  }
  for (NodeID n=0; n < g.num_nodes(); n++)
    if (!visited.get_bit(n))
      return false;
  return true;
}


int main(int argc, char* argv[]) {
  CLApp cli(argc, argv, "connected-components");
  if (!cli.ParseArgs())
    return -1;
  Builder b(cli);
  Graph g = b.MakeGraph();
  BenchmarkKernel(cli, g, ShiloachVishkin, PrintCompStats, CCVerifier);
  return 0;
}
