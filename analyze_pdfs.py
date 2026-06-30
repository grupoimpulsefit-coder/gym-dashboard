import pdfplumber, re
from collections import Counter

def get_lines(fname):
    lines = []
    with pdfplumber.open(fname) as pdf:
        for page in pdf.pages:
            t = page.extract_text()
            if t:
                lines.extend(t.split('\n'))
    return lines

lines1 = get_lines(r'C:\Users\Jose\Downloads\Ventas_por_Producto (2).pdf')
lines2 = get_lines(r'C:\Users\Jose\Downloads\Informe_de_Ventas (2).pdf')

def parse_vp(lines):
    txns = []
    i = 0
    while i < len(lines):
        m = re.match(r'(\d{2}/\d{2}/\d{4})\s+\d{2}:\d{2}:\d{2}', lines[i])
        if m:
            date = m.group(1)
            if i+1 < len(lines):
                prod_line = lines[i+1]
                nums = re.findall(r'([\d]{1,3}(?:\.\d{3})*,\d{2})', prod_line)
                if nums:
                    crc = float(nums[-1].replace('.','').replace(',','.'))
                    txns.append((date, prod_line.strip(), crc))
        i += 1
    return txns

def parse_iv(lines):
    txns = []
    for line in lines:
        if not re.search(r'\d{2}/\d{2}/\d{4}', line):
            continue
        if 'null' in line.lower():
            continue
        parts = line.strip().split()
        if parts:
            last = parts[-1]
            try:
                crc = float(last.replace(',','.'))
                txns.append((line.strip(), crc))
            except:
                pass
    return txns

vp = parse_vp(lines1)
iv = parse_iv(lines2)

sum_vp = sum(t[2] for t in vp)
sum_iv = sum(t[1] for t in iv)
print('VP total: %.0f' % sum_vp)
print('IV total: %.0f' % sum_iv)
print('Difference: %+.0f' % (sum_iv - sum_vp))
print()

vp_cnt = Counter(round(t[2]) for t in vp)
iv_cnt = Counter(round(t[1]) for t in iv)

all_keys = set(list(vp_cnt.keys()) + list(iv_cnt.keys()))
discrepancies = []
for k in sorted(all_keys):
    vc = vp_cnt.get(k, 0)
    ic = iv_cnt.get(k, 0)
    if vc != ic:
        diff = (ic - vc) * k
        discrepancies.append((k, vc, ic, diff))

print('Amount        | VP | IV | Net contribution')
print('-'*55)
net = 0
for k, vc, ic, diff in discrepancies:
    sign = '+' if diff >= 0 else ''
    print('%13.0f  | %2d | %2d | %s%d' % (k, vc, ic, sign, diff))
    net += diff
print('TOTAL NET: %+.0f' % net)
print()

print('=== Transactions in IV but NOT in VP (extra amounts) ===')
for k, vc, ic, diff in discrepancies:
    if ic > vc:
        extra = ic - vc
        print('Amount %d (IV has %d extra):' % (k, extra))
        shown = 0
        for t in iv:
            if round(t[1]) == k:
                print('  IV:', t[0])
                shown += 1
                if shown >= ic:
                    break
        print()

print('=== Transactions in VP but NOT in IV ===')
for k, vc, ic, diff in discrepancies:
    if vc > ic:
        extra = vc - ic
        print('Amount %d (VP has %d extra):' % (k, extra))
        shown = 0
        for t in vp:
            if round(t[2]) == k:
                print('  VP:', t[0], '|', t[1])
                shown += 1
                if shown >= vc:
                    break
        print()
