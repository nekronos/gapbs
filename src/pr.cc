// Copyright (c) 2015, The Regents of the University of California (Regents)
// See LICENSE.txt for license details

#include <algorithm>
#include <iostream>
#include <vector>

#include "benchmark.h"
#include "builder.h"
#include "command_line.h"
#include "graph.h"
#include "pvector.h"

/*
GAP Benchmark Suite
Kernel: PageRank (PR)
Author: Scott Beamer

Will return pagerank scores for all vertices once total change < epsilon

This PR implementation uses the traditional iterative approach. It performs
updates in the pull direction to remove the need for atomics, and it allows
new values to be immediately visible (like Gauss-Seidel method). The prior PR
implementation is still available in src/pr_spmv.cc.
*/


using namespace std;

typedef float ScoreT;
const float kDamp = 0.85;

#ifndef PR_PREFETCH_DIST
#define PR_PREFETCH_DIST 0
#endif
#ifndef PR_PREFETCH_HINT
#define PR_PREFETCH_HINT 3
#endif
#ifndef PR_PREFETCH_FLAT
#define PR_PREFETCH_FLAT 0
#endif


pvector<ScoreT> PageRankPullGS(const Graph &g, int max_iters, double epsilon=0,
                               bool logging_enabled = false) {
  const ScoreT init_score = 1.0f / g.num_nodes();
  const ScoreT base_score = (1.0f - kDamp) / g.num_nodes();
  pvector<ScoreT> scores(g.num_nodes(), init_score);
  pvector<ScoreT> outgoing_contrib(g.num_nodes());
  #pragma omp parallel for
  for (NodeID n=0; n < g.num_nodes(); n++)
    outgoing_contrib[n] = init_score / g.out_degree(n);
#if PR_PREFETCH_DIST > 0 && PR_PREFETCH_FLAT
  const NodeID *edge_end =
      g.num_nodes() > 0 ? g.in_neigh(g.num_nodes() - 1).end() : nullptr;
#endif
  for (int iter=0; iter < max_iters; iter++) {
    double error = 0;
    #pragma omp parallel for reduction(+ : error) schedule(dynamic, 16384)
    for (NodeID u=0; u < g.num_nodes(); u++) {
      ScoreT incoming_total = 0;
#if PR_PREFETCH_DIST > 0 && PR_PREFETCH_FLAT
      auto in_nb = g.in_neigh(u);
      const NodeID *last = in_nb.end();
      for (const NodeID *p = in_nb.begin(); p < last; p++) {
        // edge_end - p > D rather than p + D < edge_end: the latter forms a
        // pointer past the end of the array, which is undefined behaviour even
        // though it compiles to the same lea/cmp/cmov here.
        const NodeID *pf = (edge_end - p > PR_PREFETCH_DIST)
                               ? p + PR_PREFETCH_DIST
                               : edge_end - 1;
        __builtin_prefetch(&outgoing_contrib[*pf], 0, PR_PREFETCH_HINT);
        incoming_total += outgoing_contrib[*p];
      }
#elif PR_PREFETCH_DIST > 0
      auto in_nb = g.in_neigh(u);
      const NodeID *first = in_nb.begin();
      const NodeID *last = in_nb.end();
      const NodeID *main_end =
          (last - first > PR_PREFETCH_DIST) ? last - PR_PREFETCH_DIST : first;
      const NodeID *p = first;
      for (; p < main_end; p++) {
        __builtin_prefetch(&outgoing_contrib[*(p + PR_PREFETCH_DIST)], 0,
                           PR_PREFETCH_HINT);
        incoming_total += outgoing_contrib[*p];
      }
      for (; p < last; p++)
        incoming_total += outgoing_contrib[*p];
#else
      for (NodeID v : g.in_neigh(u))
        incoming_total += outgoing_contrib[v];
#endif
      ScoreT old_score = scores[u];
      scores[u] = base_score + kDamp * incoming_total;
      error += fabs(scores[u] - old_score);
      outgoing_contrib[u] = scores[u] / g.out_degree(u);
    }
    if (logging_enabled)
      PrintStep(iter, error);
    if (error < epsilon)
      break;
  }
  return scores;
}


void PrintTopScores(const Graph &g, const pvector<ScoreT> &scores) {
  vector<pair<NodeID, ScoreT>> score_pairs(g.num_nodes());
  for (NodeID n=0; n < g.num_nodes(); n++) {
    score_pairs[n] = make_pair(n, scores[n]);
  }
  int k = 5;
  vector<pair<ScoreT, NodeID>> top_k = TopK(score_pairs, k);
  for (auto kvp : top_k)
    cout << kvp.second << ":" << kvp.first << endl;
}


// Verifies by asserting a single serial iteration in push direction has
//   error < target_error
bool PRVerifier(const Graph &g, const pvector<ScoreT> &scores,
                        double target_error) {
  const ScoreT base_score = (1.0f - kDamp) / g.num_nodes();
  pvector<ScoreT> incoming_sums(g.num_nodes(), 0);
  double error = 0;
  for (NodeID u : g.vertices()) {
    ScoreT outgoing_contrib = scores[u] / g.out_degree(u);
    for (NodeID v : g.out_neigh(u))
      incoming_sums[v] += outgoing_contrib;
  }
  for (NodeID n : g.vertices()) {
    error += fabs(base_score + kDamp * incoming_sums[n] - scores[n]);
    incoming_sums[n] = 0;
  }
  PrintTime("Total Error", error);
  return error < target_error;
}


int main(int argc, char* argv[]) {
  CLPageRank cli(argc, argv, "pagerank", 1e-4, 20);
  if (!cli.ParseArgs())
    return -1;
  Builder b(cli);
  Graph g = b.MakeGraph();
  auto PRBound = [&cli] (const Graph &g) {
    return PageRankPullGS(g, cli.max_iters(), cli.tolerance(), cli.logging_en());
  };
  auto VerifierBound = [&cli] (const Graph &g, const pvector<ScoreT> &scores) {
    return PRVerifier(g, scores, cli.tolerance());
  };
  BenchmarkKernel(cli, g, PRBound, PrintTopScores, VerifierBound);
  return 0;
}
