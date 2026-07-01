const fs = require('fs');

const SUPA_URL = process.env.SUPA_URL;
const SUPA_KEY = process.env.SUPA_KEY;

if (!SUPA_URL || !SUPA_KEY) {
  console.error('ERROR: SUPA_URL y SUPA_KEY deben estar definidas como variables de entorno');
  process.exit(1);
}

const files = ['index.html', 'nat.html', 'sedes.html'];

files.forEach(file => {
  if (!fs.existsSync(file)) return;
  const content = fs.readFileSync(file, 'utf8')
    .replace(/__SUPA_URL__/g, SUPA_URL)
    .replace(/__SUPA_KEY__/g, SUPA_KEY);
  fs.writeFileSync(file, content, 'utf8');
  console.log(`✓ ${file}`);
});

console.log('Build completo');
