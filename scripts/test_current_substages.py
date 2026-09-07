#!/usr/bin/env python3
"""Check diagnostic timer accounting without a GPU or graph input."""
import unittest
from unittest.mock import Mock

from analyze_current_substages import parse


def fixture(instrumented=True):
    lines = [
        '[P0-ATTR] total=100 deletion=40 hotness=10 candidate=5 eviction=1 compact=2 cache_load=3',
        '[P0-DELETE-ATTR] total_ms=20 pma_delete_ms=8 invalidation_ms=2 repair_wall_ms=7',
        '[C3-CPU-MUTATION] phase=delete group_ms=2 prepare_ms=3 apply_ms=2 mutation_ms=5',
        '[C3-CPU-MUTATION] phase=add group_ms=2 prepare_ms=1 apply_ms=1 mutation_ms=3',
        '[B2-GPU-REPAIR] topology_ms=3 closure_ms=2 iterations=4 affected=5 incoming_edges=6',
        '[INSERTION-STAGE] cpu_mutation_ms=15 converge_ms=1',
        '[C3-PUBLISH] publication_ms=1',
    ]
    if instrumented:
        lines += [
            '[I14-HOST-DELETE] sync_ms=1 reclaim_ms=1 audit_ms=0 edge_prepare_ms=2 reverse_ms=10 tree_wall_ms=24 wrapper_residual_ms=0 total_ms=38',
            '[I14-DELETE-SETUP] setup_ms=3 empty=0',
            '[I14-HOST-ADD] edge_prepare_ms=1 reverse_ms=6 forward_call_ms=7',
        ]
    return '\n'.join(lines * 10)


class AttributionTest(unittest.TestCase):
    def test_legacy_logs(self):
        result = parse(Mock(read_text=lambda: fixture(False)))
        self.assertEqual(result['delete_outer_gap_ms'], 20)
        self.assertEqual(result['add_wrapper_gap_ms'], 10)
        self.assertNotIn('host_delete_reverse_ms', result)

    def test_gap_accounting(self):
        result = parse(Mock(read_text=fixture))
        self.assertEqual(result['delete_tree_unattributed_ms'], 1)
        self.assertEqual(result['delete_caller_unattributed_ms'], 2)
        self.assertEqual(result['add_wrapper_unattributed_ms'], 1)
        self.assertEqual(result['add_forward_unattributed_ms'], 2)
        self.assertEqual(result['delete_outer_gap_ms'], sum(result[key] for key in (
            'host_delete_sync_ms', 'host_delete_reclaim_ms', 'host_delete_audit_ms',
            'host_delete_edge_prepare_ms', 'host_delete_reverse_ms',
            'host_delete_wrapper_residual_ms', 'delete_setup_ms',
            'delete_tree_unattributed_ms', 'delete_caller_unattributed_ms')))
        self.assertEqual(result['add_wrapper_gap_ms'], sum(result[key] for key in (
            'host_add_edge_prepare_ms', 'host_add_reverse_ms',
            'add_wrapper_unattributed_ms', 'add_forward_unattributed_ms')))

    def test_partial_diagnostic_is_rejected(self):
        content = fixture().replace('reverse_ms=10', 'missing=10', 1)
        with self.assertRaisesRegex(ValueError, 'incomplete I14 attribution'):
            parse(Mock(read_text=lambda: content))

    def test_signed_rounding_residual(self):
        content = fixture().replace('wrapper_residual_ms=0', 'wrapper_residual_ms=-0.001')
        result = parse(Mock(read_text=lambda: content))
        self.assertAlmostEqual(result['host_delete_wrapper_residual_ms'], -0.001)

    def test_effective_batch_counters(self):
        content = fixture(False) + '\n' + '\n'.join([
            '[I14-BATCH] group_ms=1',
            '[C3-EFFECTIVE] phase=delete reverse_prepare_ms=2',
            '[C3-EFFECTIVE] phase=add reverse_prepare_ms=3',
        ] * 10)
        result = parse(Mock(read_text=lambda: content))
        self.assertEqual(result['shared_batch_group_ms'], 1)
        self.assertEqual(result['effective_delete_reverse_prepare_ms'], 2)
        self.assertEqual(result['effective_add_reverse_prepare_ms'], 3)
        self.assertNotIn('host_delete_reverse_ms', result)


if __name__ == '__main__':
    unittest.main()
