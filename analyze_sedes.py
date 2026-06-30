import pandas as pd

def load_file(path, sede):
    sheets = pd.read_excel(path, sheet_name=None, header=None)
    df_raw = list(sheets.values())[0]

    header_row = None
    for i, row in df_raw.iterrows():
        if any(str(v).strip() == "Fecha" for v in row.values):
            header_row = i
            break

    df = df_raw.iloc[header_row+1:].copy()
    df.columns = range(len(df.columns))
    header = df_raw.iloc[header_row]
    col_map = {}
    for j, v in enumerate(header):
        sv = str(v).strip()
        if sv == "Fecha": col_map["fecha"] = j
        elif sv == "Cliente": col_map["cliente"] = j
        elif sv == "Registrado Por": col_map["vendedor"] = j
        elif sv == "Producto": col_map["producto"] = j
        elif sv == "Total CRC": col_map["total_crc"] = j

    result = pd.DataFrame()
    for key, col in col_map.items():
        result[key] = df[col].values

    result["sede"] = sede
    result = result.dropna(subset=["producto", "total_crc"])
    result["total_crc"] = pd.to_numeric(result["total_crc"], errors="coerce").fillna(0)
    result["producto"] = result["producto"].astype(str).str.strip()
    result = result[result["producto"] != "nan"]
    result = result[result["total_crc"] > 0]
    result["vendedor"] = result["vendedor"].astype(str).str.strip()
    return result

files = {
    "3 Rios": r"C:\Users\Jose\Downloads\3rios.xlsx",
    "Natacion": r"C:\Users\Jose\Downloads\nata.xlsx",
    "Fita": r"C:\Users\Jose\Downloads\fita.xlsx",
    "Saba": r"C:\Users\Jose\Downloads\saba.xlsx",
}
dfs = [load_file(path, sede) for sede, path in files.items()]
df = pd.concat(dfs, ignore_index=True)

# Check Yorleny
print("=== Yorleny transactions ===")
print(df[df["vendedor"].str.contains("Yorleny", case=False, na=False)][["sede","vendedor","producto","total_crc"]].to_string())

# Check personal plans
print("\n=== Productos con 'personal' o 'ejecutivo' ===")
mask = df["producto"].str.lower().str.contains("personal|ejecutivo|png|cps", na=False)
print(df[mask][["sede","vendedor","producto","total_crc"]].to_string())
