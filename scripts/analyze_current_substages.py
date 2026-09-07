#!/usr/bin/env python3
"""Read existing profile logs; derived gaps are not isolated service timers."""
import json
from pathlib import Path
import re
import statistics
import sys

TAGS = ('P0-ATTR', 'P0-DELETE-ATTR', 'B2-GPU-REPAIR',
        'C3-CPU-MUTATION', 'INSERTION-STAGE', 'C3-PUBLISH',
        'I14-HOST-DELETE', 'I14-HOST-ADD', 'I14-DELETE-SETUP',
        'I14-BATCH', 'C3-EFFECTIVE')


def parse(path):
    result = {}
    for line in path.read_text().splitlines():
        for tag in TAGS:
            if '[' + tag + ']' not in line:
                continue
            phase = ''
            if tag in ('C3-CPU-MUTATION', 'C3-EFFECTIVE'):
                phase = '.delete' if 'phase=delete' in line else '.add'
            for key, value in re.findall(r'\b([a-z_]+)=(-?[0-9]+(?:\.[0-9]+)?)', line):
                result.setdefault(tag + phase + '.' + key, []).append(float(value))
    if len(result.get('P0-ATTR.total', [])) != 10:
        raise ValueError(f'{path}: expected ten completed batches')
    mean = lambda key: statistics.mean(result[key])
    summary = {
        'total_ms': mean('P0-ATTR.total'),
        'deletion_ms': mean('P0-ATTR.deletion'),
        'delete_outer_gap_ms': mean('P0-ATTR.deletion') - mean('P0-DELETE-ATTR.total_ms'),
        'physical_delete_ms': mean('P0-DELETE-ATTR.pma_delete_ms'),
        'delete_group_ms': mean('C3-CPU-MUTATION.delete.group_ms'),
        'delete_prepare_apply_ms': mean('C3-CPU-MUTATION.delete.prepare_ms') + mean('C3-CPU-MUTATION.delete.apply_ms'),
        'invalidation_ms': mean('P0-DELETE-ATTR.invalidation_ms'),
        'repair_wall_ms': mean('P0-DELETE-ATTR.repair_wall_ms'),
        'incoming_prepare_ms': mean('B2-GPU-REPAIR.topology_ms'),
        'gpu_closure_ms': mean('B2-GPU-REPAIR.closure_ms'),
        'repair_iterations': mean('B2-GPU-REPAIR.iterations'),
        'affected_vertices': mean('B2-GPU-REPAIR.affected'),
        'incoming_edges': mean('B2-GPU-REPAIR.incoming_edges'),
        'add_group_ms': mean('C3-CPU-MUTATION.add.group_ms'),
        'add_prepare_apply_ms': mean('C3-CPU-MUTATION.add.prepare_ms') + mean('C3-CPU-MUTATION.add.apply_ms'),
        'add_wrapper_gap_ms': mean('INSERTION-STAGE.cpu_mutation_ms') - mean('C3-CPU-MUTATION.add.group_ms') - mean('C3-CPU-MUTATION.add.mutation_ms'),
        'publication_ms': mean('C3-PUBLISH.publication_ms'),
        'insertion_closure_ms': mean('INSERTION-STAGE.converge_ms'),
        'hotness_candidate_ms': mean('P0-ATTR.hotness') + mean('P0-ATTR.candidate'),
        'cache_first3_ms': sum(sum(result['P0-ATTR.' + k][:3]) for k in ('eviction', 'compact', 'cache_load')) / 3,
        'cache_last7_ms': sum(sum(result['P0-ATTR.' + k][3:]) for k in ('eviction', 'compact', 'cache_load')) / 7,
    }
    if any(key.startswith(('I14-HOST-', 'I14-DELETE-SETUP')) for key in result):
        required = {
            'I14-HOST-DELETE': ('sync_ms', 'reclaim_ms', 'audit_ms', 'edge_prepare_ms',
                                'reverse_ms', 'tree_wall_ms', 'wrapper_residual_ms', 'total_ms'),
            'I14-HOST-ADD': ('edge_prepare_ms', 'reverse_ms', 'forward_call_ms'),
            'I14-DELETE-SETUP': ('setup_ms',),
        }
        for tag, keys in required.items():
            for key in keys:
                if len(result.get(tag + '.' + key, [])) != 10:
                    raise ValueError(f'{path}: incomplete I14 attribution: {tag}.{key}')
        for key in required['I14-HOST-DELETE']:
            summary['host_delete_' + key] = mean('I14-HOST-DELETE.' + key)
        summary['delete_setup_ms'] = mean('I14-DELETE-SETUP.setup_ms')
        summary['delete_tree_unattributed_ms'] = (
            mean('I14-HOST-DELETE.tree_wall_ms') - summary['delete_setup_ms'] -
            mean('P0-DELETE-ATTR.total_ms'))
        summary['delete_caller_unattributed_ms'] = (
            summary['deletion_ms'] - mean('I14-HOST-DELETE.total_ms'))
        for key in required['I14-HOST-ADD']:
            summary['host_add_' + key] = mean('I14-HOST-ADD.' + key)
        summary['add_wrapper_unattributed_ms'] = (
            mean('INSERTION-STAGE.cpu_mutation_ms') -
            sum(mean('I14-HOST-ADD.' + key) for key in required['I14-HOST-ADD']))
        summary['add_forward_unattributed_ms'] = (
            mean('I14-HOST-ADD.forward_call_ms') -
            mean('C3-CPU-MUTATION.add.group_ms') - mean('C3-CPU-MUTATION.add.mutation_ms'))
    if 'I14-BATCH.group_ms' in result:
        for key in ('I14-BATCH.group_ms', 'C3-EFFECTIVE.delete.reverse_prepare_ms',
                    'C3-EFFECTIVE.add.reverse_prepare_ms'):
            if len(result.get(key, [])) != 10:
                raise ValueError(f'{path}: incomplete effective batch counters: {key}')
        summary['shared_batch_group_ms'] = mean('I14-BATCH.group_ms')
        summary['effective_delete_reverse_prepare_ms'] = mean('C3-EFFECTIVE.delete.reverse_prepare_ms')
        summary['effective_add_reverse_prepare_ms'] = mean('C3-EFFECTIVE.add.reverse_prepare_ms')
    return summary


if __name__ == '__main__':
    directory = Path(sys.argv[1])
    runs = {p.stem: parse(p) for p in sorted(directory.glob('r*_*.log'))}
    means = {}
    for dataset in ('twitter', 'friendster'):
        selected = [v for k, v in runs.items() if k.endswith('_' + dataset)]
        if len(selected) != 2:
            raise ValueError(f'{dataset}: expected two runs')
        means[dataset] = {key: statistics.mean(v[key] for v in selected) for key in selected[0]}
    print(json.dumps({'runs': runs, 'means': means}, indent=2))
