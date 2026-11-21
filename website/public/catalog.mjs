const search = document.getElementById('search');
const empty = document.getElementById('catalog-empty');
const locations = [...document.querySelectorAll('[data-catalog-location]')].map((section) => ({
  section,
  groups: [...section.querySelectorAll('[data-catalog-group]')].map((group) => ({
    group,
    rows: [...group.querySelectorAll('tbody tr')].map((row) => ({ row, text: row.textContent.toLowerCase() })),
  })),
}));

search.labels[0].hidden = false;
search.hidden = false;
search.addEventListener('input', () => {
  const query = search.value.trim().toLowerCase();
  for (const { section, groups } of locations) {
    for (const { group, rows } of groups) {
      for (const { row, text } of rows) row.hidden = !text.includes(query);
      group.hidden = rows.every(({ row }) => row.hidden);
    }
    section.hidden = groups.every(({ group }) => group.hidden);
  }
  empty.hidden = locations.some(({ section }) => !section.hidden);
});
