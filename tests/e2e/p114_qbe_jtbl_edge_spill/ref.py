"""Exact reference for p114.pion (all values stay below 2^31)."""
M = 1048575


def mix(a, b):
    h = (a & M) * 31 + (b & M) + 7
    for k in range(3):
        h = (h * 5 + k) & M
    return h


def gen_code(seed, n):
    code, s = [], seed
    for _ in range(n):
        s = (s * 75 + 74) % 65537
        code.append(s % 17 - 2)
    return code


def run_vm(code, rounds, seed):
    mem = [(seed + z * 13) & 1023 for z in range(64)]
    n = len(code)
    r = [seed & 1023, (seed >> 3) & 1023, (seed >> 6) & 1023, (seed + 11) & 1023,
         (seed + 22) & 1023, (seed + 33) & 1023, (seed + 44) & 1023, (seed + 55) & 1023]
    r += [(seed + 11 * (i - 2)) & 1023 for i in range(8, 24)]
    acc, pc, steps = 1, 0, 0
    while steps < rounds and n > 0:
        op = code[pc]
        pc += 1
        if pc >= n:
            pc = 0
        steps += 1
        if op == 0:
            r[0] = (r[0] + r[1]) & M
            r[8] = (r[8] + r[0]) & M
            r[16] = (r[16] + r[8] + 1) & M
        elif op == 1:
            r[1] = (r[1] + r[2] + 1) & M
            r[9] = (r[9] + r[1]) & M
            r[17] = (r[17] + r[9] + 1) & M
        elif op == 2:
            r[2] = ((r[2] ^ r[3]) + 3) & M
            r[10] = (r[10] + r[2]) & M
            r[18] = (r[18] + r[10] + 1) & M
        elif op == 3:
            r[3] = (r[3] + r[4] * 3) & M
            r[11] = (r[11] + r[3]) & M
            r[19] = (r[19] + r[11] + 1) & M
        elif op == 4:
            r[4] = (r[4] + r[5]) & M
            r[12] = (r[12] + r[4]) & M
            r[20] = (r[20] + r[12] + 1) & M
        elif op == 5:
            r[5] = (r[5] + r[6] + steps) & M
            r[13] = (r[13] + r[5]) & M
            r[21] = (r[21] + r[13] + 1) & M
        elif op == 6:
            mem[r[0] & 63] = r[7]
            r[6] = (r[6] + 1) & M
            r[14] = (r[14] + r[6]) & M
            r[22] = (r[22] + r[14] + 1) & M
        elif op == 7:
            r[7] = (r[7] + mem[r[1] & 63]) & M
            r[15] = (r[15] + r[7]) & M
            r[23] = (r[23] + r[15] + 1) & M
        elif op == 8:
            acc = mix(acc, r[0] + r[1] + r[2] + r[3])
            r[12] = (r[12] + r[13] + r[14] + r[15] + acc) & M
            r[16] = (r[16] + r[17] + r[18] + r[19] + acc) & M
        elif op == 9:
            r[0] = mix(r[4], r[5])
            r[1] = mix(r[6], r[7])
            r[8] = (r[8] + r[9] + r[10] + r[11]) & M
            r[20] = (r[20] + r[21] + r[22] + r[23]) & M
        elif op == 11:
            if (r[0] & 3) == 0:
                break
        elif op == 13:
            pc = (r[3] & 255) % n
        else:
            acc = (acc + 1 + r[2] + op) & M
    h = (acc * 31 + steps) & M
    h = (h * 31 + pc) & M
    for v in r:
        h = (h * 31 + v) & M
    for q in range(64):
        h = (h * 3 + mem[q]) & M
    return h


total = 0
for ln in [0, 1, 2, 7, 17, 64, 257]:
    for seed in range(1, 6):
        code = gen_code(seed * 7919 + ln, ln)
        line = f'len={ln} seed={seed}'
        for ri, rounds in enumerate([0, 1, 2, 3, 19, 200, 5000]):
            v = run_vm(code, rounds, seed * 1009 + ri)
            line += f' {v}'
            total = (total * 31 + v) & M
        print(line)
print(f'total={total}')
