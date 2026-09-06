"""Validate a bounded compatibility-heap trace and compare offline placements.

Replay preserves the captured allocation lifetimes, not arbitrary guest control
flow under different addresses. Success here is never a gameplay or FPS pass.
"""
import argparse
import bisect
import collections
import json
from pathlib import Path
import struct

WORDS = struct.Struct('<8I')
MAGIC = (0x58325350, 0x50414548)
CAP = 262144


def padded(size):
    return (size + 15) & ~15


def aligned(address, alignment):
    return (address + alignment - 1) & -alignment


def read_trace(path):
    with Path(path).open('rb') as source:
        data = source.read((CAP + 2) * WORDS.size + 1)
    if len(data) < 96 or len(data) % 32 or len(data) > (CAP + 2) * 32:
        raise ValueError('Truncated or oversized heap trace')
    records = list(WORDS.iter_unpack(data))
    header, *events, footer = records
    if header[:4] != (*MAGIC, 1, 32) or header[6:] != (CAP, 16):
        raise ValueError('Unsupported trace header')
    base, limit = header[4:6]
    if not 0 < base < limit <= 0x2000000:
        raise ValueError('Invalid heap boundary')
    if footer != (5, len(events), 0, 0, 0, 0, 0, 0):
        raise ValueError('Trace is capped, interrupted or missing its failure footer')
    if not events or events[-1][0] != 4 or any(e[0] == 4 for e in events[:-1]):
        raise ValueError('Trace must end at its first failed allocation')
    return base, limit, events


def validate(base, limit, events):
    live, addresses = {}, []
    requested = occupied = peak_requested = peak_occupied = shrunk_bytes = 0
    counts = collections.Counter()
    for index, event in enumerate(events):
        op, address, size, alignment, *_ = event
        counts[op] += 1
        if op not in (1, 2, 3, 4) or not size:
            raise ValueError(f'Invalid event {index}')
        if op != 2 and (alignment < 4 or alignment & (alignment - 1)):
            raise ValueError(f'Invalid alignment at {index}')
        if op == 4:
            if address:
                raise ValueError('Failure has a nonzero address')
            continue
        if op in (2, 3):
            if address not in live:
                raise ValueError(f'Unknown free/resize at {index}: {address:#x}')
            old = live.pop(address)
            if op == 3:
                shrunk_bytes += max(0, padded(old[2]) - padded(size))
            if op == 2 and size != old[2]:
                raise ValueError(f'Free size mismatch at {index}')
            requested -= old[2]
            occupied -= padded(old[2])
            addresses.pop(bisect.bisect_left(addresses, address))
        if op in (1, 3):
            end = address + padded(size)
            position = bisect.bisect_left(addresses, address)
            if address < base or end >= limit or address % alignment:
                raise ValueError(f'Out-of-range or misaligned allocation at {index}')
            if position and addresses[position - 1] + padded(live[addresses[position - 1]][2]) > address:
                raise ValueError(f'Overlap before allocation {index}')
            if position < len(addresses) and addresses[position] < end:
                raise ValueError(f'Overlap after allocation {index}')
            # Keep the allocation origin across in-place size changes.
            live[address] = event if op == 1 else (1, address, size, alignment, *old[4:])
            addresses.insert(position, address)
            requested += size
            occupied += padded(size)
            peak_requested = max(peak_requested, requested)
            peak_occupied = max(peak_occupied, occupied)
    groups = collections.Counter()
    group_counts = collections.Counter()
    for event in live.values():
        key = event[4:]
        groups[key] += event[2]
        group_counts[key] += 1
    cursor, largest_gap = base, 0
    for address in addresses:
        largest_gap = max(largest_gap, address - cursor)
        cursor = address + padded(live[address][2])
    largest_gap = max(largest_gap, limit - 16 - cursor)
    return {
        'events': len(events), 'operations': dict(counts), 'live_count': len(live),
        'requested_bytes': requested, 'padded_bytes': occupied,
        'peak_requested_bytes': peak_requested, 'peak_padded_bytes': peak_occupied,
        'cumulative_in_place_shrink_bytes': shrunk_bytes,
        'unowned_bytes': limit - base - occupied,
        'largest_unowned_gap': largest_gap,
        'failed_size': events[-1][2],
        'origins': [dict(source=hex(key[0]), target=hex(key[1]),
                         parent_source=hex(key[2]), parent_a1=hex(key[3]),
                         live_count=group_counts[key], requested_bytes=amount)
                    for key, amount in groups.most_common(16)],
    }


class Heap:
    def __init__(self, base, limit, policy):
        self.free = [(base, limit - base - 16)]
        self.policy = policy

    def release(self, address, size):
        if not size:
            return
        i = bisect.bisect_left(self.free, (address, size))
        self.free.insert(i, (address, size))
        if i and self.free[i - 1][0] + self.free[i - 1][1] == address:
            prior, length = self.free.pop(i - 1)
            i -= 1
            self.free[i] = (prior, length + size)
        if i + 1 < len(self.free):
            address, size = self.free[i]
            following, length = self.free[i + 1]
            if address + size == following:
                self.free[i:i + 2] = [(address, size + length)]

    def allocate(self, size, alignment):
        size = padded(size)
        high = self.policy == 'large-high' and size >= 16384
        indices = range(len(self.free) - 1, -1, -1) if high else range(len(self.free))
        best = None
        for i in indices:
            address, length = self.free[i]
            start = (address + length - size) & -alignment if high else aligned(address, alignment)
            if start < address or start + size > address + length:
                continue
            if best is None or length < best[0]:
                best = (length, i, start)
            if self.policy != 'best-fit':
                break
        if best is None:
            return None
        _, i, start = best
        address, length = self.free.pop(i)
        self.release(address, start - address)
        self.release(start + size, address + length - start - size)
        return start

    def resize(self, address, old_size, size, alignment):
        old_size, size = padded(old_size), padded(size)
        if address % alignment == 0:
            if size <= old_size:
                self.release(address + size, old_size - size)
                return address
            for i, (start, length) in enumerate(self.free):
                extra = size - old_size
                if start == address + old_size and length >= extra:
                    self.free.pop(i)
                    self.release(start + extra, length - extra)
                    return address
        result = self.allocate(size, alignment)
        if result is not None:
            self.release(address, old_size)
        return result


class RuntimeHeap(Heap):
    """Match the runtime's separate bump tail and split ordering, including gaps."""
    def __init__(self, base, limit, ordered=False, frontier_first=False, recover_gaps=False):
        self.free = []
        self.bump, self.limit, self.ordered = base, limit, ordered
        self.frontier_first = frontier_first
        self.recover_gaps = recover_gaps

    def release(self, address, size):
        if not size:
            return
        entries = sorted([*self.free, (address, size)])
        self.free = []
        for start, length in entries:
            if self.free and sum(self.free[-1]) == start:
                prior, previous = self.free[-1]
                self.free[-1] = (prior, previous + length)
            else:
                self.free.append((start, length))

    def allocate(self, size, alignment):
        size = padded(size)
        for i, (address, length) in enumerate(self.free):
            start = aligned(address, alignment)
            if start + size > address + length:
                continue
            parts = []
            if start != address:
                parts.append((address, start - address))
            if start + size != address + length:
                parts.append((start + size, address + length - start - size))
            if self.ordered:
                self.free[i:i + 1] = parts
            else:
                self.free.pop(i)
                self.free.extend(parts)
            return start
        start = aligned(self.bump, alignment)
        if not self.frontier_first and start + size < self.limit:
            self.bump = start + size
            return start
        for i, (address, length) in enumerate(self.free):
            if address + length != self.bump:
                continue
            start = aligned(address, alignment)
            end = start + size
            if end >= self.limit:
                break
            self.free.pop(i)
            if start != address:
                self.free.append((address, start - address))
            if end < self.bump:
                self.free.append((end, self.bump - end))
            self.bump = max(self.bump, end)
            return start
        start = aligned(self.bump, alignment)
        if start + size < self.limit:
            if self.recover_gaps:
                self.release(self.bump, start - self.bump)
            self.bump = start + size
            return start
        return None

    def resize(self, address, old_size, size, alignment):
        old_size, size = padded(old_size), padded(size)
        if address % alignment == 0:
            if size <= old_size:
                self.release(address + size, old_size - size)
                return address
            extra = size - old_size
            for i, (start, length) in enumerate(self.free):
                if start == address + old_size and length >= extra:
                    if length == extra:
                        self.free.pop(i)
                    else:
                        self.free[i] = (start + extra, length - extra)
                    return address
        result = self.allocate(size, alignment)
        if result is not None:
            self.release(address, old_size)
        return result


def replay(base, limit, events, policy):
    heap = (RuntimeHeap(base, limit, policy != 'runtime',
                        policy in ('runtime-frontier-first', 'runtime-recover-gaps'),
                        policy == 'runtime-recover-gaps')
            if policy.startswith('runtime') else Heap(base, limit, policy))
    live, address_mismatches = {}, 0
    for index, event in enumerate(events):
        op, original, size, alignment, *_ = event
        if op == 2:
            address, old_size = live.pop(original)
            heap.release(address, padded(old_size))
            continue
        if op == 3:
            address, old_size = live[original]
            result = heap.resize(address, old_size, size, alignment)
        else:
            result = heap.allocate(size, alignment)
        if result is None:
            return {'policy': policy, 'captured_prefix_fits': False,
                    'failed_event': index, 'failed_op': op, 'failed_size': size,
                    'address_mismatches': address_mismatches,
                    'untouched_tail': heap.limit - heap.bump if isinstance(heap, RuntimeHeap) else None,
                    'free_bytes': sum(n for _, n in heap.free),
                    'largest_free': max((n for _, n in heap.free), default=0)}
        if op != 4:
            address_mismatches += result != original
            live[original] = (result, size)
    return {'policy': policy, 'captured_prefix_fits': True,
            'address_mismatches': address_mismatches,
            'untouched_tail': heap.limit - heap.bump if isinstance(heap, RuntimeHeap) else None,
            'free_after_failed_request': sum(n for _, n in heap.free),
            'largest_free': max((n for _, n in heap.free), default=0)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--expect-model', choices=('runtime', 'runtime-frontier-first', 'runtime-recover-gaps'))
    args = parser.parse_args()
    base, limit, events = read_trace(args.trace)
    result = validate(base, limit, events)
    result['replays'] = [replay(base, limit, events, policy)
                         for policy in ('runtime', 'runtime-ordered-split', 'runtime-frontier-first', 'runtime-recover-gaps', 'first-fit', 'best-fit', 'large-high')]
    if args.expect_model:
        exact = next(item for item in result['replays'] if item['policy'] == args.expect_model)
        if (exact['captured_prefix_fits'] or exact['address_mismatches'] or
                exact['failed_event'] != len(events) - 1):
            raise ValueError('Expected allocator model did not reproduce every address and the first failure')
        result['exact_model_verified'] = args.expect_model
    result['scope'] = ('Captured lifetime prefix only; not a gameplay or FPS pass. '
                       'Runtime models retain bump/alignment-gap behavior. Other models '
                       'use address-ordered free lists and recover alignment gaps.')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
