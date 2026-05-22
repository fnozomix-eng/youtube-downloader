import re
with open('page_source.html', 'r', encoding='utf-8') as f:
    html = f.read()
links = list(set(re.findall(r'https://(?:www\.)?(?:youtube\.com|youtu\.be|youtube\.com/live)/[^\s"\'<>]+', html)))
with open('urls.txt', 'w') as f:
    f.write('\n'.join(links))
print(f'{len(links)}個のリンクを抽出しました')