import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('heap_replay', Path(__file__).parents[1] / 'replay-heap-trace.py')
heap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heap)


def event(op, address, size, alignment=16):
    return (op, address, size, alignment, 0x248068, 0x231ed0, 0x2dd20c, 12)


class HeapTraceTests(unittest.TestCase):
    def test_ledger_rejects_overlaps(self):
        with self.assertRaisesRegex(ValueError, 'Overlap'):
            heap.validate(0x1000, 0x2000, [event(1, 0x1000, 64), event(1, 0x1010, 64)])

    def test_ledger_rejects_missing_frees(self):
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            heap.validate(0x1000, 0x2000, [event(2, 0x1000, 64, 0)])

    def test_ledger_rejects_bad_resize(self):
        with self.assertRaisesRegex(ValueError, 'Overlap'):
            heap.validate(0x1000, 0x2000, [event(1, 0x1000, 16),
                event(1, 0x1010, 16), event(3, 0x1000, 32)])

    def test_ledger_preserves_origin_after_resize(self):
        resize = (3, 0x1000, 32, 16, 0x8888, 0x9999, 0, 0)
        result = heap.validate(0x1000, 0x2000, [event(1, 0x1000, 64), resize, event(4, 0, 8192)])
        self.assertEqual(result['requested_bytes'], 32)
        self.assertEqual(result['peak_requested_bytes'], 64)
        self.assertEqual(result['origins'][0]['source'], '0x248068')

    def test_header_footer_and_cap(self):
        header = (*heap.MAGIC, 1, 32, 0x1000, 0x2000, heap.CAP, 16)
        failure = event(4, 0, 8192)
        footer = (5, 1, 0, 0, 0, 0, 0, 0)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'trace.bin'
            path.write_bytes(b''.join(heap.WORDS.pack(*r) for r in (header, failure, footer)))
            self.assertEqual(heap.read_trace(path), (0x1000, 0x2000, [failure]))
            for bad in ((6, 1, 0, 0, 0, 0, 0, 0), (5, 2, 0, 0, 0, 0, 0, 0)):
                path.write_bytes(b''.join(heap.WORDS.pack(*r) for r in (header, failure, bad)))
                with self.assertRaisesRegex(ValueError, 'footer'):
                    heap.read_trace(path)
            path.write_bytes(heap.WORDS.pack(*header) + b'partial')
            with self.assertRaisesRegex(ValueError, 'Truncated'):
                heap.read_trace(path)

    def test_release_coalesces_both_neighbors(self):
        memory = heap.Heap(0x1000, 0x1100, 'first-fit')
        blocks = [memory.allocate(32, 16) for _ in range(3)]
        memory.release(blocks[0], 32)
        memory.release(blocks[2], 32)
        memory.release(blocks[1], 32)
        self.assertEqual(memory.free, [(0x1000, 240)])

    def test_runtime_split_order(self):
        original = heap.RuntimeHeap(0x1000, 0x2000)
        ordered = heap.RuntimeHeap(0x1000, 0x2000, ordered=True)
        for memory in (original, ordered):
            memory.free = [(0x1000, 64), (0x1200, 64)]
            memory.bump = 0x1800
            self.assertEqual(memory.allocate(16, 16), 0x1000)
        self.assertEqual(original.allocate(16, 16), 0x1200)
        self.assertEqual(ordered.allocate(16, 16), 0x1010)

    def test_runtime_model_reproduces_failure_addresses(self):
        events = [event(1, 0x1000, 64), event(1, 0x1040, 16),
                  event(2, 0x1000, 64, 0), event(1, 0x1000, 32), event(4, 0, 8192)]
        result = heap.replay(0x1000, 0x2000, events, 'runtime')
        self.assertEqual(result['address_mismatches'], 0)
        self.assertEqual(result['failed_event'], 4)

    def test_runtime_recovers_alignment_gap(self):
        memory = heap.RuntimeHeap(0x1000, 0x2000, True, True, True)
        self.assertEqual(memory.allocate(16, 16), 0x1000)
        self.assertEqual(memory.allocate(16, 256), 0x1100)
        self.assertEqual(memory.allocate(208, 16), 0x1010)

    def test_policies_have_distinct_placement(self):
        first, best = (heap.Heap(0x1000, 0x2000, p) for p in ('first-fit', 'best-fit'))
        for memory in (first, best):
            memory.free = [(0x1000, 128), (0x1200, 48)]
        self.assertEqual(first.allocate(32, 16), 0x1000)
        self.assertEqual(best.allocate(32, 16), 0x1200)
        high = heap.Heap(0x1000, 0x10000, 'large-high')
        self.assertEqual(high.allocate(16384, 256), 0xBF00)
        self.assertEqual(high.allocate(16, 16), 0x1000)

    def test_resize_failure_preserves_original(self):
        memory = heap.Heap(0x1000, 0x1100, 'first-fit')
        block = memory.allocate(32, 16)
        guard = memory.allocate(32, 16)
        self.assertIsNone(memory.resize(block, 32, 512, 16))
        self.assertEqual(memory.free, [(guard + 32, 176)])
        memory.release(guard, 32)
        self.assertEqual(memory.resize(block, 32, 128, 16), block)
        self.assertEqual(memory.resize(block, 128, 16, 16), block)
        self.assertEqual(memory.free, [(block + 16, 224)])

    def test_replay_tracks_reused_original_addresses(self):
        events = [event(1, 0x1000, 64), event(2, 0x1000, 64, 0),
                  event(1, 0x1000, 32), event(4, 0, 8192)]
        for policy in ('first-fit', 'best-fit', 'large-high'):
            result = heap.replay(0x1000, 0x2000, events, policy)
            self.assertFalse(result['captured_prefix_fits'])
            self.assertEqual(result['failed_event'], 3)


if __name__ == '__main__':
    unittest.main()
