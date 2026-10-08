                        if (ii == end_vertex) {
                            // Legacy in-place ordering assumes a left-moving
                            // anchor. When the entire remaining window moves
                            // right, snapshot this window before redistribution.
                            // Keep the old weighted positions/density policy.
                            std::vector<index_t> saved;
                            saved.reserve(segment_edges_actual[pma_idx]);
                            for (index_t s = start_vertex; s < end_vertex; ++s)
                                saved.insert(saved.end(), edges_ + sync_vertices_[s].index,
                                    edges_ + sync_vertices_[s].index + sync_vertices_[s].degree);
                            size_t cursor = 0;
                            for (index_t s = start_vertex; s < end_vertex; ++s) {
                                std::copy_n(saved.data() + cursor, sync_vertices_[s].degree,
                                    edges_ + new_index[s - start_vertex]);
                                cursor += sync_vertices_[s].degree;
                                sync_vertices_[s].index = new_index[s - start_vertex];
                            }
                            free(new_index);
                            recount_segment_total(start_vertex, end_vertex);
                            return;
                        }
