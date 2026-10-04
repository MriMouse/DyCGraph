# 3 System Overview

We present a CPU–GPU cooperative system for out-of-memory streaming graph processing (Figure 1). §4 introduces a heterogeneous graph organization that confines adjacency changes and corresponding updates on the GPU and elsewhere to modified source vertices. A unified change view coordinates outgoing adjacency, the reverse index, and GPU views, reducing redundant maintenance across these structures. Building on this organization, §5 develops two-phase incremental computation: deletion repair followed by insertion propagation. Compact work lists identify affected vertices, guiding CPU preparation of incoming edges for GPU repair and GPU traversal from vertices whose results improve. This cooperation restricts data preparation and graph traversal to the affected computation and its dependencies, reducing redundant computation and CPU–GPU communication.

<!-- Figure 1 artwork to be inserted. Drawing specification: 架构图绘制说明与提示词_20260917.md -->

*Figure 1: Core mechanisms for graph organization (§4) and incremental computation (§5). The inset illustrates supporting data structures; CPU/GPU labels indicate execution placement.*
