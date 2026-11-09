#!/usr/bin/env bash
# Busca en la Wikipedia local (Kiwix) y devuelve el primer artículo en Markdown limpio.
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "❌ Error: Debes proporcionar un término de búsqueda." >&2
  exit 1
fi

QUERY="$*"
KIWIX_URL="${KIWIX_URL:-http://127.0.0.1:10002}"
PYTHON="${WIKI_PYTHON:-/home/yo/maple/venv/bin/python}"
MAX_WORDS="${MAX_WORDS:-2000}"
CURL=(curl -fsS --max-time 15)

# Dependencia: sin Kiwix no hay búsqueda. Mensaje claro en vez de un error críptico de curl.
if ! curl -fs -o /dev/null --max-time 3 "$KIWIX_URL/"; then
  echo "❌ Kiwix no responde en $KIWIX_URL (revisa: systemctl status kiwix-wiki.service)" >&2
  exit 1
fi

# Primer resultado de la búsqueda (URL absoluta); vacío si no hay resultados
ARTICLE_URL=$("${CURL[@]}" -G "$KIWIX_URL/search" \
    --data-urlencode "pattern=$QUERY" --data-urlencode "pageLength=5" |
  "$PYTHON" -c '
import sys
from urllib.parse import urljoin
from bs4 import BeautifulSoup
soup = BeautifulSoup(sys.stdin.read(), "html.parser")
box = soup.find("div", class_="results")
link = box.find("a", href=True) if box else None
if link:
    print(urljoin(sys.argv[1] + "/", link["href"]))
' "$KIWIX_URL")

if [ -z "$ARTICLE_URL" ]; then
  echo "⚠️ No articles found for: '$QUERY'"
  exit 0
fi

# Artículo -> HTML -> texto limpio (títulos, párrafos y listas) con recorte por palabras.
# Sin pandoc: así no hay escapes tipo \[ ... \] (que Page Assist interpreta como fórmula LaTeX)
# ni cortes de párrafo en mitad de una frase.
"${CURL[@]}" -L "$ARTICLE_URL" |
"$PYTHON" -c '
import re
import sys
from bs4 import BeautifulSoup

max_words = int(sys.argv[1])
soup = BeautifulSoup(sys.stdin.read(), "html.parser")

for el in soup(["script", "style", "link", "meta", "noscript", "nav", "footer", "header",
                "aside", "table", "sup", "img", "figure", "audio", "button"]):
    el.decompose()
NOISY = ["kiwixNav", "kiwixfooter", "mw-jump-link", "infobox", "navbox", "thumb", "reference",
         "mw-ref", "ext-phonos", "mw-editsection", "noprint"]
for el in soup.find_all(class_=NOISY):
    el.decompose()
content = soup.find("div", id="mw-content-text") or soup.find("body") or soup

# Secciones finales sin valor para el modelo (se corta al llegar a la primera)
STOP = {"references", "notes", "footnotes", "external links", "see also", "further reading",
        "bibliography", "sources", "referencias", "notas", "enlaces externos", "véase también",
        "bibliografía"}

def clean(t):
    t = t.replace("\u2009", " ").replace("\xa0", " ")
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"\s+([,.;:!?)\]])", r"\1", t)     # espacio antes de puntuación
    t = re.sub(r"([(\[])\s+", r"\1", t)           # espacio tras ( o [
    t = re.sub(r"\(\s*[;,:]?\s*\)", "", t)        # paréntesis vacíos
    t = re.sub(r" {2,}", " ", t)
    return t.replace("$", "\\$")                  # un $ suelto activaría el modo fórmula

def own_text(li):
    # texto del <li> sin el de sus sublistas (esas tienen sus propios <li>)
    return "".join(s for s in li.find_all(string=True) if s.find_parent(["ul", "ol"]) is li.parent)

out, count, trimmed, prev_li = [], 0, False, False
for el in content.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li"]):
    name = el.name
    if name == "p" and el.find_parent(["li", "p"]):
        continue                                   # ya incluido en su <li> / <p> contenedor
    text = clean(own_text(el) if name == "li" else el.get_text())
    if not text:
        continue
    if name[0] == "h":
        if text.lower() in STOP:
            break
        text = "#" * min(int(name[1]), 4) + " " + text
    elif name == "li":
        text = "- " + text

    words = text.split()
    if count + len(words) > max_words:
        remaining = max_words - count
        if remaining > 0:
            out.append(" ".join(words[:remaining]))
        trimmed = True
        break
    if name == "li" and prev_li:
        out[-1] += "\n" + text                     # elementos de lista consecutivos juntos
    else:
        out.append(text)
    prev_li = name == "li"
    count += len(words)

if trimmed:
    out.append("[... Content trimmed to %d words ...]" % max_words)
print("\n\n".join(out) if out else "")
' "$MAX_WORDS"
