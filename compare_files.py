import pandas as pd

print("=" * 60)
print("DIAGNÓSTICO: FILAS DE SUBTOTALES EN CADA ARCHIVO")
print("=" * 60)

# ── FILE 1 ─────────────────────────────────────────────────────────────────
df1 = pd.read_excel(r"C:\Users\Jose\Downloads\Ventas_por_Producto (14).xlsx", header=None)
h1  = df1.iloc[3]
crc1 = next(j for j, v in enumerate(h1) if str(v).strip() == "Total CRC")
data1 = df1.iloc[4:].copy()
data1.columns = range(len(data1.columns))
data1["crc"] = pd.to_numeric(data1[crc1], errors="coerce").fillna(0)
# Fila fecha = NaN → es subtotal
fecha1 = next(j for j, v in enumerate(h1) if str(v).strip() == "Fecha")
subtotals1 = data1[data1[fecha1].isna() & (data1["crc"] > 0)]
real1       = data1[data1[fecha1].notna() & (data1["crc"] > 0)]
print(f"\n[1] Ventas x Producto membresías (14):")
print(f"    Total bruto (con subtotales): CRC {data1['crc'].sum():>15,.0f}")
print(f"    Subtotales detectados:        CRC {subtotals1['crc'].sum():>15,.0f}")
print(f"    ─────────────────────────────────────────────────")
print(f"    TOTAL REAL (sin subtotales):  CRC {real1['crc'].sum():>15,.0f}")

# ── FILE 2 ─────────────────────────────────────────────────────────────────
df2 = pd.read_excel(r"C:\Users\Jose\Downloads\Informe_de_Ventas (13).xlsx", header=None)
h2   = df2.iloc[6]
crc2  = next(j for j, v in enumerate(h2) if str(v).strip() == "Total CRC")
imp2  = next(j for j, v in enumerate(h2) if str(v).strip() == "Impuestos CRC")
fecha2 = next(j for j, v in enumerate(h2) if str(v).strip() == "Fecha")
data2  = df2.iloc[7:].copy()
data2.columns = range(len(data2.columns))
data2["crc"] = pd.to_numeric(data2[crc2], errors="coerce").fillna(0)
data2["imp"] = pd.to_numeric(data2[imp2], errors="coerce").fillna(0)
subtotals2   = data2[data2[fecha2].isna() & (data2["crc"] > 0)]
real2        = data2[data2[fecha2].notna() & (data2["crc"] > 0)]
print(f"\n[2] Informe de Ventas membresías (13):")
print(f"    Total bruto (con subtotales): CRC {data2['crc'].sum():>15,.0f}")
print(f"    Subtotales detectados:        CRC {subtotals2['crc'].sum():>15,.0f}")
print(f"    ─────────────────────────────────────────────────")
print(f"    TOTAL REAL (sin subtotales):  CRC {real2['crc'].sum():>15,.0f}")
print(f"    Impuestos CRC incluidos:      CRC {real2['imp'].sum():>15,.0f}")
print(f"    Total neto (sin impuestos):   CRC {(real2['crc']-real2['imp']).sum():>15,.0f}")
print(f"    Subtotales detectados: {len(subtotals2)} filas con valores: {subtotals2['crc'].tolist()}")

# ── FILE 3: fita2 ──────────────────────────────────────────────────────────
df3 = pd.read_excel(r"C:\Users\Jose\Downloads\fita2.xlsx", header=None)
h3  = df3.iloc[3]
crc3   = next(j for j, v in enumerate(h3) if str(v).strip() == "Total CRC")
prod3  = next(j for j, v in enumerate(h3) if str(v).strip() == "Producto")
fecha3 = next(j for j, v in enumerate(h3) if str(v).strip() == "Fecha")
data3  = df3.iloc[4:].copy()
data3.columns = range(len(data3.columns))
data3["crc"]  = pd.to_numeric(data3[crc3],  errors="coerce").fillna(0)
data3["prod"] = data3[prod3].astype(str).str.strip()
subtotals3   = data3[data3[fecha3].isna() & (data3["crc"] > 0)]
real3        = data3[data3[fecha3].notna() & (data3["crc"] > 0)]

MEMBERSHIP_KW = [
    "plan","clases","nataci","gym","trimestre","semestre","anual",
    "sesion","sesi","renovaci","activos","verano","black friday",
    "estimulaci","aquafitness","fit gym","lealtad","platiu","platinum",
    "standar","estandar","exclusivo","bloqueado","multigym","mensual",
    "estudiante","adulto mayor","corporativo","aniversario","inactivo",
    "promo","clase baile","clase grupal","gym incluido","nat amor",
    "ex nat","ex 3 nat","natacion adultos","ejecutivo","png","cps"
]
real3_memb = real3[real3["prod"].apply(lambda p: any(k in str(p).lower() for k in MEMBERSHIP_KW))]

print(f"\n[3] fita2 (Ventas x Producto completo):")
print(f"    Total bruto (con subtotales): CRC {data3['crc'].sum():>15,.0f}")
print(f"    Subtotales detectados:        CRC {subtotals3['crc'].sum():>15,.0f}")
print(f"    ─────────────────────────────────────────────────")
print(f"    TOTAL REAL todo:              CRC {real3['crc'].sum():>15,.0f}")
print(f"    TOTAL REAL membresías:        CRC {real3_memb['crc'].sum():>15,.0f}")
print(f"    Subtotales: {len(subtotals3)} filas")

# ── RESUMEN ─────────────────────────────────────────────────────────────────
t1 = real1["crc"].sum()
t2 = real2["crc"].sum()
t3m = real3_memb["crc"].sum()
print(f"\n{'='*60}")
print("RESUMEN FINAL (sin subtotales):")
print(f"  [1] VxProd membresías sistema: CRC {t1:>14,.0f}")
print(f"  [2] Informe Ventas membresías: CRC {t2:>14,.0f}  (incl. impuestos)")
print(f"  [3] fita2 membresías (filtro): CRC {t3m:>14,.0f}")
print(f"\n  Diff [1] vs [2]: {t1-t2:>+,.0f}")
print(f"  Diff [1] vs [3]: {t1-t3m:>+,.0f}")
print(f"  Diff [2] vs [3]: {t2-t3m:>+,.0f}")

# ── Explicar diff [1] vs [3] ────────────────────────────────────────────────
# Products in system (FILE1) but not caught by our filter
p1_names = set(real1["prod" if "prod" in real1.columns else prod3]
               .astype(str).str.replace(r"\s*\(Membres.*", "", regex=True).str.strip())
print(f"\nProductos que el SISTEMA clasifica como Membresía pero nuestro filtro podría diferir:")
prods1_col = next(j for j, v in enumerate(h1) if str(v).strip() == "Producto")
unique_prods1 = real1[prods1_col].astype(str).str.replace(r"\s*\(Membres.*","",regex=True).str.strip().unique()
for p in sorted(unique_prods1):
    ok = any(k in str(p).lower() for k in MEMBERSHIP_KW)
    if not ok:
        print(f"  ❌ NO capturado por nuestro filtro: '{p}'")
