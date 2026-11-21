const navigation = document.querySelector('.catalog-nav');
if (navigation) {
  const links = [...navigation.querySelectorAll('a')];
  const sections = links.map((link) => document.getElementById(link.hash.slice(1)));
  for (const section of sections) enableCatalog(section);
  function showLocation() {
    const active = links.find((link) => link.hash === location.hash) ?? links[0];
    for (const [index, link] of links.entries()) {
      if (link === active) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
      sections[index].hidden = link !== active;
    }
  }
  for (const link of links) {
    link.addEventListener('click', (event) => {
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      if (location.hash !== link.hash) history.pushState(null, '', link.hash);
      showLocation();
    });
  }
  window.addEventListener('hashchange', showLocation);
  showLocation();
}

function enableCatalog(section) {
  const local = section.id === 'local';
  const form = section.querySelector('form');
  const status = section.querySelector('.catalog-status');
  const table = section.querySelector('table');
  const headings = [...table.tHead.rows[0].cells];
  const collation = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
  const groups = [...table.tBodies].map((body) => {
    const label = body.querySelector('[data-creator-label]');
    const toggle = body.querySelector('[data-creator-toggle]');
    const count = toggle.querySelector('[data-creator-count]');
    const rows = [...body.querySelectorAll('[data-model-id]')].map((element) => {
      const values = [...element.cells].map((cell, index) => {
        if (cell.dataset.value === '') return null;
        return headings[index].dataset.sortType === 'number' ? Number(cell.dataset.value) : cell.dataset.value;
      });
      const { modelId, type, capabilities = '' } = element.dataset;
      const provider = local ? '' : values[1];
      const searchable = [values[0], modelId, body.dataset.creator, provider, capabilities,
        element.hasAttribute('data-abliterated') ? 'abliterated' : ''].join(' ').toLowerCase();
      return { element, values, type, provider, searchable, capabilities: capabilities.split(', ') };
    });
    const group = { body, toggle, count, rows, visible: rows, expanded: rows.length === 1 };
    label.hidden = true;
    toggle.hidden = false;
    toggle.addEventListener('click', () => {
      group.expanded = !group.expanded;
      updateGroup(group);
    });
    return group;
  });

  let sortColumn = -1;
  let direction = 1;

  function updateGroup({ body, toggle, count, rows, visible, expanded }) {
    body.hidden = visible.length === 0;
    count.textContent = visible.length;
    toggle.setAttribute('aria-expanded', String(expanded));
    const matching = new Set(visible);
    for (const row of rows) row.element.hidden = !expanded || !matching.has(row);
  }

  function compare(a, b) {
    const left = a?.values[sortColumn] ?? null;
    const right = b?.values[sortColumn] ?? null;
    if (left === null) return right === null ? 0 : 1;
    if (right === null) return -1;
    return direction * (typeof left === 'number' ? left - right : collation.compare(left, right));
  }

  function sortGroups() {
    const order = sortColumn < 0 ? groups : [...groups].sort((a, b) => compare(a.visible[0], b.visible[0]));
    table.append(...order.map((group) => group.body));
  }

  function applyFilters() {
    const filters = Object.fromEntries(new FormData(form));
    const query = filters.query.toLowerCase().trim();
    const filtering = Boolean(query || Object.entries(filters).some(([name, value]) => name !== 'query' && value));
    let matches = 0;
    for (const group of groups) {
      group.visible = group.rows.filter((row) => {
        if (!row.searchable.includes(query) || (filters.creator && filters.creator !== group.body.dataset.creator)
          || (filters.type && filters.type !== row.type)) return false;
        if (!local) {
          return (!filters.provider || filters.provider === row.provider)
            && (!filters.capability || row.capabilities.includes(filters.capability));
        }
        const [, , , memory, score] = row.values;
        return (!filters.memory || (memory !== null && memory <= Number(filters.memory)))
          && (!filters.hardware || !row.element.hasAttribute('data-metal'))
          && (!filters.abliterated || row.element.hasAttribute('data-abliterated'))
          && matchesScore(score, filters.score);
      });
      if (sortColumn >= 0) group.visible.sort(compare);
      group.expanded = filtering || group.rows.length === 1;
      matches += group.visible.length;
      updateGroup(group);
    }
    sortGroups();
    status.textContent = matches ? `${matches} ${matches === 1 ? 'model' : 'models'}` : 'No models match your filters.';
    table.parentElement.hidden = matches === 0;
  }

  for (const [index, heading] of headings.entries()) {
    const button = heading.querySelector('button');
    button.disabled = false;
    button.addEventListener('click', () => {
      direction = index === sortColumn ? -direction : 1;
      if (sortColumn >= 0) headings[sortColumn].removeAttribute('aria-sort');
      sortColumn = index;
      heading.setAttribute('aria-sort', direction > 0 ? 'ascending' : 'descending');
      for (const group of groups) {
        group.visible.sort(compare);
        group.body.append(...[...group.rows].sort(compare).map((row) => row.element));
      }
      sortGroups();
    });
  }
  form.addEventListener('submit', (event) => event.preventDefault());
  form.addEventListener('input', applyFilters);
  form.addEventListener('reset', () => queueMicrotask(applyFilters));
  form.hidden = false;
  status.hidden = false;
  applyFilters();
}

function matchesScore(score, filter) {
  switch (filter) {
    case '': return true;
    case 'scored': return score !== null;
    case 'unscored': return score === null;
    default: return score !== null && score >= Number(filter);
  }
}
