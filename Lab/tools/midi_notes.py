"""Minimal Standard MIDI File reader: prints/returns notes per track as (start_beat, dur_beats, midi, vel)."""
import struct, sys, json

def read_vlq(b, i):
    v = 0
    while True:
        c = b[i]; i += 1
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80: return v, i

def parse(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'MThd'
    fmt, ntr, div = struct.unpack('>HHH', b[8:14])
    i = 14; tracks = []; meta = {'tempo': [], 'timesig': [], 'keysig': [], 'names': []}
    for t in range(ntr):
        assert b[i:i+4] == b'MTrk'; ln = struct.unpack('>I', b[i+4:i+8])[0]; j = i + 8; end = j + ln; i = end
        tick = 0; status = 0; on = {}; notes = []
        while j < end:
            d, j = read_vlq(b, j); tick += d
            c = b[j]
            if c == 0xFF:
                typ = b[j+1]; l, k = read_vlq(b, j+2); data = b[k:k+l]; j = k + l
                if typ == 0x51: meta['tempo'].append((tick/div, 60_000_000 / int.from_bytes(data, 'big')))
                elif typ == 0x58: meta['timesig'].append((tick/div, data[0], 2**data[1]))
                elif typ == 0x59: meta['keysig'].append((tick/div, int.from_bytes(data[:1], 'big', signed=True), data[1]))
                elif typ == 0x03: meta['names'].append((t, data.decode('latin1')))
                continue
            if c in (0xF0, 0xF7):
                l, k = read_vlq(b, j+1); j = k + l; continue
            if c & 0x80: status = c; j += 1
            hi = status & 0xF0
            if hi in (0x80, 0x90):
                n, v = b[j], b[j+1]; j += 2
                if hi == 0x90 and v > 0: on.setdefault(n, []).append((tick, v))
                elif on.get(n):
                    s, vv = on[n].pop(0); notes.append((s/div, (tick-s)/div, n, vv))
            elif hi in (0xC0, 0xD0): j += 1
            else: j += 2
        tracks.append(sorted(notes))
    return meta, tracks

if __name__ == '__main__':
    meta, tracks = parse(sys.argv[1])
    print(json.dumps({'meta': meta, 'tracks': [len(t) for t in tracks]}))
