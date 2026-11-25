"""Python reference of prog/ (the p116 multi-file Pion package)."""


def make_code(seed, n):
    code, s = [], seed
    for _ in range(n):
        s = (s * 75 + 74) % 65537
        code.append(s % 13 - 1)
    return code


def slow_mix(a, b):
    while b > 0:
        a, b = (a * 5 + b) & 1048575, b - 1
    return a & 1048575


def interp(code, seed, rounds):
    n = len(code)
    r = [(seed + k) & 1023 for k in range(12)]
    acc = pc = step = 0
    while step < rounds and n > 0:
        op = code[pc]
        if op == 0: r[0] = (r[0] + r[1]) & 1023
        elif op == 1: r[1] = (r[1] ^ r[2]) & 1023
        elif op == 2: r[2] = (r[2] + r[3] * 3) & 1023
        elif op == 3: r[3] = (r[3] + r[4]) & 1023
        elif op == 4: r[4] = (r[4] ^ (r[5] + 1)) & 1023
        elif op == 5: r[5] = (r[5] + r[6] + r[7]) & 1023
        elif op == 6: acc = slow_mix(acc + r[6] + r[8], 3)
        elif op == 7: r[7] = (r[7] + r[8] * 5) & 1023
        elif op == 9: r[9] = (r[9] + r[10]) & 1023
        elif op == 10: r[10] = (r[10] ^ r[11]) & 1023
        elif op == 11: r[11] = (r[11] + r[0] + 1) & 1023
        else: acc = (acc + op + 2) & 1048575
        r[8] = (r[8] + 1) & 1023
        pc += 1
        if pc >= n:
            pc = 0
        step += 1
    return (acc + sum(r[k] * (k + 1) for k in range(12))) & 1048575


def fold_hash(seed, n):
    x, y = seed, 0
    for i in range(n):
        if i & 3 == 0: x = (x * 5 + i) & 65535
        elif i & 3 == 1: y = (y + x) & 65535
        else: x = (x + y + 1) & 65535
    return (x * 65536 + y) & 1048575


def word_mix(seed, n):
    a = [seed & 4095, (seed >> 2) & 4095, (seed + 7) & 4095, (seed + 13) & 4095,
         (seed + 29) & 4095, (seed + 31) & 4095]
    for i in range(n):
        a[0] = (a[0] + a[1]) & 4095
        a[1] = (a[1] ^ a[2]) & 4095
        a[2] = (a[2] + a[3] * 3) & 4095
        if i % 7 == 3:
            a[3] = ((a[3] * 33) + a[4]) & 4095
        a[4] = (a[4] + a[5] + i) & 4095
        a[5] = (a[5] ^ a[0]) & 4095
    return (a[0] + a[1] * 3 + a[2] * 5 + a[3] * 7 + a[4] * 11 + a[5] * 13) & 1048575


total = 0
for seed in range(1, 7):
    v = interp(make_code(seed * 7919, 40 + seed * 9), seed * 31, 64 * seed)
    h = fold_hash(seed, 300 + seed)
    w = word_mix(seed * 1009, 50)
    print(f"seed={seed} vm={v} fold={h} mix={w}")
    total = (total * 131 + v + h + w) & 1048575
print(f"total={total}")
