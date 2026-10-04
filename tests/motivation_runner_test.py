"""CPU-only checks for experiment completeness and ratio-of-totals aggregation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('motivation',Path(__file__).resolve().parents[1]/'scripts/run_motivation_sssp.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class MotivationRunnerTest(unittest.TestCase):
    def record(self,batch,mode):
        return dict(batch=batch,mode=mode,**{f:100 for f in m.COUNT_FIELDS},compute_ms=10,rebuild_ms=2,rebuild_groups=1)

    def log(self,records):
        return '\n'.join('[MOTIVATION] '+json.dumps(r)+'\n[P0-TIMER][SSSP][batch '+str(r['batch'])+'] total_batch: 20.000 ms' for r in records)

    def test_missing_duplicate_or_wrong_mode_rejected(self):
        records=[self.record(i,'counts') for i in range(10)]
        self.assertEqual(len(m.parse_log(self.log(records),'counts')),10)
        for invalid in (records[:-1],records+[records[-1]],records[::-1]):
            with self.assertRaises(ValueError): m.parse_log(self.log(invalid),'counts')
        with self.assertRaises(ValueError): m.parse_log(self.log(records),'timing')
        with self.assertRaises(ValueError): m.parse_log(self.log(records)+'\nCUDA error','counts')

    def test_means_require_two_successes_and_share_uses_totals(self):
        with tempfile.TemporaryDirectory() as folder:
            out=Path(folder)
            for mode in ('counts','timing'):
                for rep in (1,2):
                    records=[self.record(i,mode) for i in range(10)]
                    for r in records:
                        r.update(compute_ms=10 if rep==1 else 90,rebuild_ms=5 if rep==1 else 9,paper_batch_ms=100)
                    result=dict(dataset='TW',system='current',mode=mode,repeat=rep,status='ok',batches=records)
                    (out/f'SSSP_TW_current_{mode}_r{rep}.result.json').write_text(json.dumps(result))
            m.summarize(out)
            rows=json.loads((out/'averages.json').read_text()); row=rows[0]
            self.assertEqual(row['mean_updated_sources'],100)
            self.assertAlmostEqual(row['rebuild_share_pct'],14)
            self.assertEqual(row['status'],'complete')
            self.assertIsNone(rows[1]['mean_updated_sources'])
            path=out/'SSSP_TW_current_counts_r2.result.json'
            failed=json.loads(path.read_text()); failed['status']='failed'; path.write_text(json.dumps(failed))
            m.summarize(out)
            row=json.loads((out/'averages.json').read_text())[0]
            self.assertIsNone(row['mean_updated_sources'])
            self.assertEqual(row['status'],'pending_or_failed')
            self.assertFalse((out/'table_rows.tex').exists())

if __name__=='__main__': unittest.main()
