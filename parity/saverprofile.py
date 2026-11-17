"""Reads the traces parity/test-saver.sh records of the running saver.

  saverprofile.py cpu <time-profile.xml>      where the saver's CPU samples go
  saverprofile.py gpu <metal-gpu-intervals.xml> <seconds>
                                              GPU busy ms a second, by process

The GPU figure is the union of a process's intervals on every channel (vertex,
fragment, compute overlap on Apple GPUs), so it is the time the GPU spent on
that process at all -- the saver's own, and WindowServer's compositing of it.
"""
import collections, sys
import xml.etree.ElementTree as ET


def rows(path):
    """Each row's cells, with the export's id/ref sharing resolved, and the
    resolver itself: a backtrace's frames are shared the same way."""
    root = ET.parse(path).getroot()
    ids = {el.attrib['id']: el for el in root.iter() if 'id' in el.attrib}
    deref = lambda e: ids[e.attrib['ref']] if 'ref' in e.attrib else e
    for row in root.iter('row'):
        yield [deref(e) for e in row], deref


def walk(el, deref):
    """Every element under el, following refs: a tagged backtrace can hold its
    backtrace, and a backtrace its frames, by reference to an earlier row's."""
    el = deref(el)
    yield el
    for child in el:
        yield from walk(child, deref)


def cpu(path):
    inclusive, total = collections.Counter(), 0
    for cells, deref in rows(path):
        proc = next((e for e in cells if e.tag == 'process'), None)
        if proc is None or 'legacyScreenSaver' not in proc.attrib.get('fmt', ''):
            continue
        weight = next((e for e in cells if e.tag == 'weight'), None)
        w = int(weight.text) if weight is not None and weight.text else 1
        trace = next((e for e in cells if e.tag in ('backtrace', 'tagged-backtrace')), None)
        if trace is None:
            continue
        total += w
        for name in {f.attrib.get('name', '') for f in walk(trace, deref) if f.tag == 'frame'} - {''}:
            inclusive[name] += w
    if not total:
        sys.exit('no saver samples in the trace')
    # Inclusive shares of the saver's samples, for the parts this project owns.
    for key in ('draw(HyperspaceSaverSettings', 'goo::', 'tunnel::', 'starBurst', 'flare',
                'HSRendererMetal::', 'nextDrawable', 'animateOneFrame'):
        share = max([w for n, w in inclusive.items() if key in n] or [0])
        print(f'  {key:30s} {100 * share / total:5.1f}% of the saver')


def gpu(path, seconds):
    spans = collections.defaultdict(list)
    for cells, _ in rows(path):
        start = next((e for e in cells if e.tag == 'start-time'), None)
        dur = next((e for e in cells if e.tag == 'duration'), None)
        proc = next((e for e in cells if e.tag == 'process'), None)
        if start is None or dur is None or proc is None:
            continue
        # Name and pid: a second legacyScreenSaver (a preview, another
        # display) is another row, not added to the saver's.
        name = proc.attrib.get('fmt', '')
        s = int(start.text)
        spans[name].append((s, s + int(dur.text)))
    busy = {}
    for name, intervals in spans.items():
        total, end = 0, -1
        for s, e in sorted(intervals):
            if e <= end:
                continue
            total += e - max(s, end)
            end = e
        busy[name] = total
    for name in sorted(busy, key=lambda n: -busy[n]):
        print(f'  {name:36s} GPU busy {busy[name] / 1e6 / seconds:7.2f} ms a second')


if __name__ == '__main__':
    if sys.argv[1] == 'cpu':
        cpu(sys.argv[2])
    else:
        gpu(sys.argv[2], float(sys.argv[3]))
