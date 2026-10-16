# Skills de Claude Code del proyecto

Copiadas tal cual de sus repos (licencia en cada carpeta):

| Skill | Origen | Commit |
|---|---|---|
| `ponytail`, `ponytail-review`, `ponytail-audit`, `ponytail-debt` | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) (MIT) | 84740e3 |
| `security-and-hardening` | [addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) (MIT) | aeac41d |

Cambio local: en `security-and-hardening/SKILL.md` las rutas `../../references/security-checklist.md`
apuntan ahora a `references/security-checklist.md` (copiado dentro de la skill), y las de
`references/hardening-patterns.md` a `security-checklist.md`.

Sin los hooks del plugin de ponytail: no hay modo siempre activo ni statusline; la skill se
activa por su descripción o con `/ponytail [lite|full|ultra]`.
