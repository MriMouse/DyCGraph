#!/usr/bin/env python3
"""CPU-only regression checks for source isolation, switches and the run plan."""
import importlib.util, json, tempfile, unittest
from pathlib import Path
HERE=Path(__file__).resolve().parent

def module(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    obj=importlib.util.module_from_spec(spec);spec.loader.exec_module(obj);return obj
prepare=module('prepare');experiment=module('experiment')

class PreparationTest(unittest.TestCase):
    def test_frozen_control_and_all_combinations(self):
        base=prepare.DEFAULT_BASE
        paths=['include/framework/framework.cuh','include/groute/graphs/csr_graph.cuh',
               'include/framework/variants/driver.cuh']
        paths += [f'samples/hybrid_{a}/{f}.cu' for a in ('sssp','bfs') for f in (f'hybrid_{a}','main')]
        frozen={p:(base/p).read_bytes() for p in paths}
        with tempfile.TemporaryDirectory() as tmp:
            for v in ('111','011','101','110','000','001','010','100'):
                dest=Path(tmp)/v
                for p,data in frozen.items():
                    path=dest/p;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
                prepare.transform(dest,*map(int,v))
                f=(dest/paths[0]).read_text();c=(dest/paths[1]).read_text()
                if v=='111':
                    for p in paths:
                        if not p.endswith('/main.cu'):self.assertEqual((dest/p).read_bytes(),frozen[p])
                self.assertEqual('new topology::SourceLocalChunkStore(vcsr_graph)' in f,v[0]=='0')
                self.assertEqual('kernel::AblationScanReset<<<' in f,v[1]=='0')
                self.assertEqual('m_ablation_full_descriptors.resize' in c,v[2]=='0')
                if v[2]=='0':self.assertNotIn('PatchOrInvalidateCachedAdjacency<<<m_publication_count',c)
                if v[1]=='0':
                    self.assertIn('static constexpr bool kSupportsGpuDeletionRepair = false;',
                        (dest/'samples/hybrid_bfs/hybrid_bfs.cu').read_text())
            for p,data in frozen.items():self.assertEqual((base/p).read_bytes(),data)
    def test_fixture_and_oracle(self):
        with tempfile.TemporaryDirectory() as tmp:
            graph,updates,sizes,expected=experiment.fixture(Path(tmp))
            self.assertEqual(len(sizes.read_text().splitlines()),5)
            self.assertEqual(expected['BFS'][2],expected['BFS'][3]) # no-op batch
            self.assertNotEqual(expected['SSSP'][0],expected['BFS'][0])
            self.assertEqual(len(expected['BFS']),5)
            self.assertTrue(graph.exists() and updates.exists())
    def test_plan(self):
        root=prepare.ROOT/'build/ablation_20261004_ready'
        plan=json.loads((root/'plan/plan.json').read_text())
        self.assertEqual(plan['total'],192)
        self.assertFalse(plan['launches_gpu'])
        for t in plan['tasks']:
            argv=t['argv']
            self.assertIn('--check=false',argv)
            self.assertIn('--hybrid=0',argv)
            self.assertEqual(Path(argv[2]),experiment.binary(root,t['variant'],t['algorithm']))
            self.assertTrue(all(Path(x.split('=',1)[1]).exists() for x in argv if x.startswith(('--graphfile=','--updatefile=','--update_size='))))
        self.assertEqual([t['variant'] for t in plan['tasks'][:8]],['111','011','101','110','110','101','011','111'])
if __name__=='__main__':unittest.main()
