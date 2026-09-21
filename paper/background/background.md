2 Background

A streaming graph evolves through a sequence of mutations, including vertex and edge insertions, deletions, and property updates (some). Let $G_t=(V_t,E_t)$ denote the graph at time $t$ and $\Delta G_t$ a batch of mutations. Applying this batch produces a new graph snapshot:

\[
G_{t+1}=\operatorname{Apply}(G_t,\Delta G_t).
\]

For a graph algorithm $\mathcal{A}$, let $R_t=\mathcal{A}(G_t)$ denote its result on $G_t$. Graph mutations may invalidate previously computed values and induce changes in the result:

\[
R_{t+1}=\mathcal{A}(G_{t+1}), \qquad
\Delta R_t=\operatorname{Diff}(R_t,R_{t+1}),
\]

where $\operatorname{Diff}$ identifies the output values that change between snapshots. For instance, inserting an edge can shorten shortest-path distances. Deleting an edge that is not contained in any shortest path leaves all shortest-path distances unchanged.
By contrast, deleting an edge that is contained in a shortest path can increase the distances of vertices that are several hops away—by forcing a switch to an alternative shortest path—or even render those vertices unreachable. Streaming graph processing must therefore both maintain the evolving graph and update analysis results to reflect its mutations.

2.1 CPU-based Streaming Graph Processing

A line of research on streaming graph processing has primarily focused on efficient storage and analysis of graph data on CPU-based platforms.
To support frequent mutations without sacrificing traversal efficiency, STINGER uses linked lists of edge blocks and parallel batch updates (STINGER), while Terrace adapts storage to vertex degree through in-place arrays, a shared packed memory array, and per-vertex B-trees (Terrace).
To allow updates and analytics to proceed concurrently on consistent graph views, GraphOne combines an edge log with adjacency storage and dual versioning to decouple ingestion from computation (GraphOne), while LiveGraph uses a multiversion Transactional Edge Log (TEL) to support transactional updates with purely sequential adjacency scans (LiveGraph).
For parallel graph computation, Ligra provides vertex and edge mapping primitives and switches traversal strategies according to the density of the active vertex set, primarily for static graphs (Ligra).
These techniques improve graph access and the scheduling of computational resources, but efficient storage alone cannot eliminate recomputation after data mutation. Even when $\Delta R_t$ comprises only a small number of changed values, the system must still recompute $R_{t+1}$ from scratch, incurring substantial redundant work. Moreover, as hardware continues to advance, the parallel computing capacity of CPUs is increasingly being outpaced.

2.2 GPU-based Graph Processing

With advances in GPUs, graph processing increasingly exploits massive parallelism and high memory bandwidth, as many graph algorithms are inherently parallel over vertices and edges.
A key challenge in GPU-based dynamic graph processing is supporting frequent mutations while preserving efficient adjacency access. Many systems address this challenge through storage designs that improve update and read efficiency. To maintain ordered edges without rebuilding CSR after each batch, GPMA+ uses a packed memory array with parallel batch updates (GPMA+), while LPMA introduces a leveled organization to reduce array expansion and rebalancing costs (LPMA).
To manage changing adjacency sizes, Hornet allocates adjacency lists in blocks with power-of-two capacities (Hornet), while faimGraph uses linked pages and autonomous GPU memory management to support both vertex and edge updates (faimGraph). 
To accelerate edge lookup and avoid duplicates during insertion, SHGraph stores each vertex's neighbors in a GPU hash table (SHGraph). Beyond storage, SEP-Graph dynamically adapts its execution mode, communication mechanism, and traversal strategy to the workload characteristics of each iteration (SEP-Graph).

As graph sizes grow beyond GPU memory capacity, out-of-memory processing stores graph data in host memory and accesses it from the GPU, making host–GPU data transfer a major bottleneck. 
For static graphs, Subway reduces unnecessary transfers by generating subgraphs containing only active edges and processing them asynchronously (Subway), while EMOGI avoids coarse-grained migration through zero-copy access to host memory, using coalesced and aligned cache-line requests (EMOGI). The effectiveness of these transfer strategies varies with the active workload: explicit transfers can incur subgraph compaction and redundant copying, whereas fine-grained on-demand accesses can underutilize interconnect bandwidth. To address this variation, HyTGraph uses a cost model to select between explicit transfers and zero-copy accesses for graph partitions, together with asynchronous scheduling that prioritizes computations according to their expected contributions to convergence (HyTGraph). However, accelerating traversal and reducing transfers do not by themselves determine how to reuse previously computed results after graph mutations.

2.3 Incremental Graph Computation

Dependency-based incremental computation tracks how vertex values depend on other values and uses these dependencies to identify computations affected by graph mutations. KickStarter, GraphBolt, and DZiG share this approach, reusing valid results and propagating changes through dependencies to avoid restarting the entire computation. To safely reuse results after edge deletions, KickStarter trims affected intermediate values using dependency information, providing a valid starting point for further iterations in a class of monotonic graph algorithms (KickStarter). To support algorithms requiring Bulk Synchronous Parallel (BSP) semantics, GraphBolt tracks dependencies across iterations and incrementally refines intermediate values to reflect graph mutations (GraphBolt). DZiG further addresses the redundant propagation that remains when incremental computations become sparse, using a recursive formulation to identify and prune unnecessary updates while preserving BSP semantics (DZiG).

Recent work has explored CPU–GPU cooperation and incremental computation in out-of-memory graph processing. CGgraph keeps a reusable subgraph in GPU memory and distributes computation between the CPU and GPU through on-demand task allocation, allowing the CPU to actively participate in graph analytics (CGgraph). However, its design targets static graphs. Grapin introduces a dependency-based incremental computation mechanism that enables incremental processing for memory-constrained GPU-based streaming graph analysis by decoupling result updates from dependency updates into GPU-native atomic operations (Grapin). Although this approach enhances processing efficiency, Grapin executes graph computations solely on the GPU, leaving the CPU's computational capabilities underutilized for graph analysis. Consequently, effectively integrating CPU-GPU collaborative mechanisms with the incremental processing of dynamically evolving graphs remains a key direction for further optimization in this field.