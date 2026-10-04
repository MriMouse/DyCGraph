import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('runner',ROOT/'scripts/run_road_communication_20261003.py')
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
spec=importlib.util.spec_from_file_location('full',ROOT/'scripts/run_evaluation_full.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)

class ContractTest(unittest.TestCase):
    def test_road_switch_only_current(self):
        obj=object.__new__(r.Runner);obj.out=ROOT/'paper/evaluation/raw/road_communication_20261003'
        for alg in ('SSSP','BFS'):
            for side in ('original','current'):
                argv,env=obj.command(alg,'EU','1k',side)
                road,renv=obj.command(alg,'EU','1k',side,road=True)
                self.assertEqual([x for x in argv if not x.startswith(('--graphfile=','--updatefile=','--update_size='))],[x for x in road if not x.startswith(('--graphfile=','--updatefile=','--update_size='))])
                differences={k for k in env.keys()|renv.keys() if env.get(k)!=renv.get(k)}
                self.assertEqual(differences,{'CG_ORDERED_REPAIR'} if side=='current' else set())
                self.assertEqual(renv['CG_COMM_METER'],'0')
                self.assertEqual(renv['CG_COMM_WINDOW'],'0')
    def test_inverse_legal_and_duplicate_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            graph=Path(td)/'graph';graph.write_text('0 1\n1 2\n2 0\n')
            batches=[dict(d=[(0,1,1)],a=[(0,2,1)])]
            cycle,audit=f.audit_cycle(graph,batches)
            self.assertTrue(audit['restores_base_topology'])
            self.assertEqual(cycle[-1],dict(d=[(0,2,1)],a=[(0,1,1)]))
            with self.assertRaises(ValueError):f.audit_cycle(graph,batches+batches)
    def test_timer_rejects_missing_duplicate(self):
        obj=object.__new__(r.Runner)
        valid='[P0-TIMER][BFS][batch 0] total_batch: 1.25\n[P0-TIMER][BFS][batch 1] total_batch: 2.5'
        self.assertEqual(obj.timing(valid,'BFS',2),3.75)
        with self.assertRaises(ValueError):obj.timing(valid,'BFS',3)
        with self.assertRaises(ValueError):obj.timing(valid+valid,'BFS',2)


class DirectPlanTest(unittest.TestCase):
    def test_conservative_duration_plan(self):
        obj=object.__new__(r.Runner)
        obj.rows=[dict(group='communication',dataset='TW',algorithm='SSSP',scale='1k',cycles=4,physical=dict(duration_s=8.0))]
        self.assertEqual(obj.communication_cycles('BFS','FS','100k'),5)
        obj.rows=[]
        self.assertEqual(obj.communication_cycles('SSSP','TW','1k'),10)

if __name__=='__main__':unittest.main()
