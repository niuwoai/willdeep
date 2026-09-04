(function () {
  'use strict';

  var MAX_TAGS = 20;
  var MAX_TAG_LENGTH = 40;
  var MONTH_CELLS = 42;
  var CUSTOM_PROJECT = '__custom_project__';

  function node(tag, className, text) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }
  function icon(name) {
    var element = node('span', 'icon icon-' + name);
    element.setAttribute('aria-hidden', 'true');
    return element;
  }
  function button(text, className, action, iconName) {
    var element = node('button', className);
    element.type = 'button';
    if (iconName) element.appendChild(icon(iconName));
    if (text) element.appendChild(node('span', '', text));
    if (action) element.addEventListener('click', action);
    return element;
  }
  function iconButton(name, label, action) {
    var element = button('', 'icon-button', action, name);
    element.setAttribute('aria-label', label);
    element.title = label;
    return element;
  }
  function selectControl(entries, value, label, onChange) {
    var select = node('select', 'detail-control');
    select.setAttribute('aria-label', label);
    entries.forEach(function (entry) {
      var option = node('option', '', entry[1]);
      option.value = entry[0];
      select.appendChild(option);
    });
    select.value = value;
    select.addEventListener('change', function () { onChange(select.value); });
    return select;
  }
  function key(name) { return String(name).normalize('NFC').trim().replace(/^#+/, '').trim().toLowerCase(); }
  function normalizeTags(tags) {
    var seen = Object.create(null);
    return (Array.isArray(tags) ? tags : []).filter(function (name) {
      if (typeof name !== 'string') return false;
      var normalized = key(name);
      if (!normalized || seen[normalized]) return false;
      seen[normalized] = true;
      return true;
    }).map(function (name) { return name.normalize('NFC').trim().replace(/^#+/, '').trim(); });
  }
  function dayKey(date) {
    return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
  }
  function parseDay(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
    var parts = value.split('-').map(Number);
    var date = new Date(parts[0], parts[1] - 1, parts[2], 12);
    return dayKey(date) === value ? date : null;
  }
  function calendarDays(month) {
    var first = new Date(month.getFullYear(), month.getMonth(), 1, 12);
    first.setDate(first.getDate() - (first.getDay() + 6) % 7);
    return Array.from({ length: MONTH_CELLS }, function (_, index) {
      return new Date(first.getFullYear(), first.getMonth(), first.getDate() + index, 12);
    });
  }
  function dueValue(draft) {
    if (!draft.date) return '';
    var date = parseDay(draft.date);
    if (!date || (!draft.allDay && !/^([01]\d|2[0-3]):[0-5]\d$/.test(draft.time))) return null;
    var clock = draft.allDay ? [23, 59] : draft.time.split(':').map(Number);
    date.setHours(clock[0], clock[1], draft.allDay ? 59 : 0, 0);
    if (dayKey(date) !== draft.date || date.getHours() !== clock[0] || date.getMinutes() !== clock[1]) return null;
    return date.toISOString();
  }
  function draftFor(item) {
    var date = item.due ? new Date(item.due) : null;
    return {
      projectPath: item.projectPath || '', tags: normalizeTags(item.tags),
      date: date ? dayKey(date) : '',
      time: date ? String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0') : '09:00',
      allDay: !!date && !!item.allDay, priority: item.priority || ''
    };
  }
  function projectEntries(projects, workspace, selected, t) {
    var entries = [['', t('scopeInbox')]];
    var seen = {};
    (projects || []).concat([{ path: workspace }, { path: selected }]).forEach(function (project) {
      var path = project.path;
      if (!path || seen[path]) return;
      seen[path] = true;
      entries.push([path, project.name || path.replace(/\/$/, '').split('/').pop()]);
    });
    return entries;
  }
  function tagChip(name, action, t) {
    var chip = button(name, 'tag-chip', action, 'tag');
    chip.dataset.tone = String(Array.from(name).reduce(function (sum, character) { return sum + character.codePointAt(0); }, 0) % 3);
    if (t) {
      chip.appendChild(icon('x-mark'));
      chip.setAttribute('aria-label', t('removeTag', name));
    }
    return chip;
  }
  function checkRow(label, checked, action, count) {
    var row = node('label', 'tag-option');
    var input = node('input');
    input.type = 'checkbox'; input.checked = checked;
    input.addEventListener('change', function () { action(input.checked); });
    row.appendChild(input); row.appendChild(node('span', '', label));
    if (count !== undefined) row.appendChild(node('span', 'count', String(count)));
    return row;
  }

  function renderFilters(container, options) {
    var t = options.t, state = options.state;
    var focused = document.activeElement;
    var reopenTags = !!container.querySelector('details[open]');
    var searchText = container.querySelector('[data-tag-search]');
    searchText = searchText ? searchText.value : '';
    var restoreSearch = focused && focused.hasAttribute('data-tag-search');
    container.textContent = '';
    var entries = [['all', t('scopeAll')], ['inbox', t('scopeInbox')]];
    projectEntries(options.projects, options.workspace, state.projectPath, t).slice(1).forEach(function (entry) {
      entries.push([entry[0], entry[1]]);
    });
    var project = selectControl(entries, state.scope === 'project' ? state.projectPath : state.scope, t('project'), function (value) {
      options.change({ scope: value === 'all' || value === 'inbox' ? value : 'project', projectPath: value === 'all' || value === 'inbox' ? '' : value });
    });
    project.className = 'filter-select'; container.appendChild(project);
    var status = selectControl([['open', t('statusOpen')], ['done', t('statusDone')], ['all', t('statusAll')]], state.status, t('statusAll'), function (value) { options.change({ status: value }); });
    status.className = 'filter-select'; container.appendChild(status);

    // 常用标签直接铺出来，不必先点开一个 details 才知道有哪些。铺几个
    // 取决于筛选行还剩多少地方，多了会把这一行撑成两行；剩下的仍在「更多」里。
    var INLINE_TAGS = 6;
    var inlineSource = options.tags.slice(0, INLINE_TAGS);
    if (inlineSource.length) {
      var inline = node('div', 'tag-inline');
      inlineSource.forEach(function (entry) {
        var active = state.tags.some(function (name) { return key(name) === key(entry.name); });
        var chip = node('button', 'chip');
        chip.type = 'button';
        chip.setAttribute('aria-pressed', String(active));
        chip.appendChild(node('span', '', entry.name));
        if (entry.count) chip.appendChild(node('span', 'n', String(entry.count)));
        chip.addEventListener('click', function () {
          var next = state.tags.filter(function (name) { return key(name) !== key(entry.name); });
          if (!active) next.push(entry.name);
          if (next.length <= MAX_TAGS) options.change({ tags: next, withoutTags: false });
        });
        inline.appendChild(chip);
      });
      container.appendChild(inline);
    }

    var details = node('details', 'tag-filter'); details.open = reopenTags;
    var summary = node('summary', 'chip'); summary.appendChild(icon('tag'));
    summary.appendChild(node('span', '', (inlineSource.length ? t('moreTags') : t('tags')) + (state.tags.length ? ' ' + state.tags.length : '')));
    summary.setAttribute('aria-label', t('filterTags')); details.appendChild(summary);
    var menu = node('div', 'tag-filter-menu');
    var search = node('input', 'tag-search'); search.type = 'search'; search.placeholder = t('filterTagSearch');
    search.setAttribute('aria-label', t('filterTagSearch')); search.setAttribute('data-tag-search', ''); search.value = searchText;
    menu.appendChild(search);
    menu.appendChild(checkRow(t('noTags'), state.withoutTags, function (checked) { options.change({ withoutTags: checked, tags: [] }); }, options.untaggedCount));
    var list = node('div', 'tag-options'); menu.appendChild(list);
    function renderOptions() {
      list.textContent = '';
      var available = options.tags.slice();
      state.tags.forEach(function (name) { if (!available.some(function (entry) { return key(entry.name) === key(name); })) available.push({ name: name, count: 0 }); });
      available.filter(function (entry) { return key(entry.name).indexOf(key(search.value)) >= 0; }).forEach(function (entry) {
        var checked = state.tags.some(function (name) { return key(name) === key(entry.name); });
        list.appendChild(checkRow(entry.name, checked, function (selected) {
          var next = state.tags.filter(function (name) { return key(name) !== key(entry.name); });
          if (selected) next.push(entry.name);
          if (next.length <= MAX_TAGS) options.change({ tags: next, withoutTags: false });
        }, entry.count));
      });
      if (!list.childElementCount) list.appendChild(node('p', 'detail-help', t('noTagMatches')));
    }
    search.addEventListener('input', renderOptions); renderOptions();
    details.appendChild(menu); container.appendChild(details);
    if (restoreSearch) search.focus();
    state.tags.forEach(function (name) {
      container.appendChild(tagChip(name, function () { options.change({ tags: state.tags.filter(function (tag) { return key(tag) !== key(name); }) }); }, t));
    });
    if (state.withoutTags) container.appendChild(button(t('noTags'), 'tag-chip', function () { options.change({ withoutTags: false }); }));
    if (state.tags.length) {
      var mode = selectControl([['any', t('anyTag')], ['all', t('everyTag')]], state.tagMode, t('filterTags'), function (value) { options.change({ tagMode: value }); });
      mode.className = 'filter-select'; container.appendChild(mode);
    }
    if (state.tags.length || state.withoutTags) container.appendChild(button(t('clearFilters'), 'text-action', function () { options.change({ tags: [], withoutTags: false, tagMode: 'any' }); }));
  }

  function createInspector(options) {
    var root = options.root, t = options.t;
    var item = null, draft = null, original = '', month = new Date(), saving = false, returnFocus = null;
    var projects = [], tags = [], elements = {};
    var compact = window.matchMedia('(max-width: 979px)');

    function dirty() { return draft && JSON.stringify(draft) !== original; }
    function confirmLeave(action) {
      if (saving) return false;
      if (!dirty()) return true;
      var previous = root.querySelector('.discard-confirmation');
      if (previous) previous.remove();
      var confirmation = node('div', 'discard-confirmation');
      confirmation.setAttribute('role', 'alert');
      confirmation.appendChild(node('p', '', t('discard')));
      var keep = button(t('keepEditing'), 'chip', function () { confirmation.remove(); elements.project.focus(); });
      confirmation.appendChild(keep);
      confirmation.appendChild(button(t('discardChanges'), 'chip', function () { original = JSON.stringify(draft); action(); }));
      elements.footer.before(confirmation); keep.focus(); return false;
    }
    function updateLayout() {
      var active = !!item;
      options.main.inert = active && compact.matches;
      root.setAttribute('role', compact.matches ? 'dialog' : 'region');
      if (active && compact.matches) root.setAttribute('aria-modal', 'true');
      else root.removeAttribute('aria-modal');
    }
    compact.addEventListener('change', updateLayout);
    function close(force) {
      if (!force && !confirmLeave(function () { close(true); })) return false;
      item = null; draft = null; root.classList.add('hidden');
      options.layout.classList.remove('has-details'); updateLayout(); options.onClose();
      if (returnFocus && returnFocus.isConnected) returnFocus.focus();
      else options.main.querySelector('input').focus();
      return true;
    }
    function field(labelText, content) {
      var wrap = node('div', 'detail-field');
      var label = node('label', 'detail-label', labelText);
      if (content.id) label.htmlFor = content.id;
      wrap.appendChild(label); wrap.appendChild(content); return wrap;
    }
    function error(text) { elements.error.textContent = text; elements.error.classList.toggle('hidden', !text); }
    function projectField() {
      var entries = projectEntries(projects, options.workspace(), draft.projectPath, t);
      entries.push([CUSTOM_PROJECT, t('otherProject')]);
      var select = selectControl(entries, draft.projectPath, t('project'), function (value) {
        elements.path.classList.toggle('hidden', value !== CUSTOM_PROJECT);
        draft.projectPath = value === CUSTOM_PROJECT ? elements.path.value.trim() : value;
        if (value === CUSTOM_PROJECT) elements.path.focus();
      });
      select.id = 'detail-project'; elements.project = select;
      var wrap = field(t('project'), select);
      var path = node('input', 'detail-control hidden'); path.type = 'text'; path.placeholder = t('projectPathHint');
      path.setAttribute('aria-label', t('projectPath')); path.maxLength = 4096;
      path.addEventListener('input', function () { draft.projectPath = path.value.trim(); });
      elements.path = path; wrap.appendChild(path); wrap.appendChild(node('p', 'detail-help', t('projectHelp')));
      return wrap;
    }
    function changeTag(name, selected) {
      var next = draft.tags.filter(function (tag) { return key(tag) !== key(name); });
      if (selected) next.push(name);
      if (next.length > MAX_TAGS || Array.from(name).length > MAX_TAG_LENGTH || /[\u0000-\u001f\u007f]/.test(name)) { error(t('tagLimit')); return false; }
      draft.tags = normalizeTags(next); error(''); renderTags(); return true;
    }
    function renderTags() {
      elements.chips.textContent = ''; elements.suggestions.textContent = '';
      draft.tags.forEach(function (name) { elements.chips.appendChild(tagChip(name, function () { changeTag(name, false); }, t)); });
      var query = key(elements.tagSearch.value);
      var names = normalizeTags(tags.map(function (tag) { return tag.name; }).concat(draft.tags));
      names.filter(function (name) { return key(name).indexOf(query) >= 0; }).forEach(function (name) {
        elements.suggestions.appendChild(checkRow(name, draft.tags.some(function (tag) { return key(tag) === key(name); }), function (checked) { changeTag(name, checked); }));
      });
      var canCreate = query && !names.some(function (name) { return key(name) === query; });
      elements.create.classList.toggle('hidden', !canCreate);
      elements.create.lastChild.textContent = t('createTag', elements.tagSearch.value.trim());
    }
    function tagsField() {
      var wrap = node('div', 'detail-field'); wrap.appendChild(node('label', 'detail-label', t('tags')));
      elements.chips = node('div', 'detail-tags'); wrap.appendChild(elements.chips);
      elements.tagSearch = node('input', 'tag-search'); elements.tagSearch.type = 'search';
      elements.tagSearch.placeholder = t('tagSearch'); elements.tagSearch.setAttribute('aria-label', t('tagSearch'));
      elements.tagSearch.maxLength = MAX_TAG_LENGTH * 2;
      elements.tagSearch.addEventListener('input', renderTags); wrap.appendChild(elements.tagSearch);
      elements.suggestions = node('div', 'detail-suggestions'); wrap.appendChild(elements.suggestions);
      function createTag() {
        var name = normalizeTags([elements.tagSearch.value])[0];
        if (name && changeTag(name, true)) { elements.tagSearch.value = ''; renderTags(); }
      }
      elements.create = button(t('newTag'), 'create-tag', createTag, 'plus'); wrap.appendChild(elements.create);
      elements.tagSearch.addEventListener('keydown', function (event) {
        if (event.key === 'Enter') { event.preventDefault(); createTag(); }
      });
      renderTags(); return wrap;
    }
    function pickDay(date, focusDay) {
      draft.date = dayKey(date); if (!draft.time) draft.time = '09:00';
      month = new Date(date.getFullYear(), date.getMonth(), 1, 12); renderCalendar();
      if (focusDay) elements.grid.querySelector('[data-day="' + draft.date + '"]').focus();
    }
    function renderCalendar() {
      elements.month.textContent = month.toLocaleDateString(options.locale(), { year: 'numeric', month: 'long' });
      elements.grid.textContent = '';
      var week;
      calendarDays(month).forEach(function (date, index) {
        if (index % 7 === 0) { week = node('div', 'calendar-week'); week.setAttribute('role', 'row'); elements.grid.appendChild(week); }
        var value = dayKey(date);
        var day = button(String(date.getDate()), 'calendar-day' + (date.getMonth() !== month.getMonth() ? ' outside-month' : ''), function () { pickDay(date, true); });
        day.dataset.day = value; day.setAttribute('role', 'gridcell');
        day.setAttribute('aria-label', date.toLocaleDateString(options.locale(), { year: 'numeric', month: 'long', day: 'numeric', weekday: 'long' }));
        day.setAttribute('aria-selected', String(value === draft.date));
        day.tabIndex = value === (draft.date || dayKey(new Date())) ? 0 : -1;
        if (value === dayKey(new Date())) day.setAttribute('aria-current', 'date');
        day.addEventListener('keydown', function (event) {
          var offsets = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
          if (offsets[event.key] === undefined) return;
          event.preventDefault(); var next = new Date(date); next.setDate(next.getDate() + offsets[event.key]); pickDay(next, true);
        });
        week.appendChild(day);
      });
      if (!elements.grid.querySelector('[tabindex="0"]')) elements.grid.querySelector('.calendar-day:not(.outside-month)').tabIndex = 0;
      elements.time.disabled = !draft.date || draft.allDay;
      elements.time.value = draft.date ? draft.time : '';
      elements.allDay.disabled = !draft.date; elements.allDay.checked = draft.allDay;
      elements.noDeadline.checked = !draft.date;
    }
    function dateField() {
      var picker = node('div', 'date-picker'); picker.id = 'detail-date';
      var header = node('div', 'month-header');
      function changeMonth(delta) { month = new Date(month.getFullYear(), month.getMonth() + delta, 1, 12); renderCalendar(); }
      header.appendChild(iconButton('chevron-left', t('previousMonth'), function () { changeMonth(-1); }));
      elements.month = node('span'); elements.month.setAttribute('aria-live', 'polite'); header.appendChild(elements.month);
      header.appendChild(iconButton('chevron-right', t('nextMonth'), function () { changeMonth(1); })); picker.appendChild(header);
      var weekdays = node('div', 'calendar-weekdays'); weekdays.setAttribute('aria-hidden', 'true');
      t('weekdays').forEach(function (label) { weekdays.appendChild(node('span', '', label)); }); picker.appendChild(weekdays);
      elements.grid = node('div', 'calendar-grid'); elements.grid.setAttribute('role', 'grid'); elements.grid.setAttribute('aria-label', t('date')); picker.appendChild(elements.grid);
      var row = node('div', 'date-time-row'); row.appendChild(icon('clock'));
      elements.time = node('input'); elements.time.type = 'time'; elements.time.setAttribute('aria-label', t('time'));
      elements.time.addEventListener('input', function () { draft.time = elements.time.value; }); row.appendChild(elements.time);
      var allDayLabel = node('label', 'all-day', t('allDay'));
      elements.allDay = node('input'); elements.allDay.type = 'checkbox';
      elements.allDay.addEventListener('change', function () { draft.allDay = elements.allDay.checked; renderCalendar(); });
      allDayLabel.appendChild(elements.allDay); row.appendChild(allDayLabel); picker.appendChild(row);
      var none = node('label', 'no-deadline');
      elements.noDeadline = node('input'); elements.noDeadline.type = 'radio'; elements.noDeadline.name = 'todo-no-deadline';
      elements.noDeadline.addEventListener('change', function () { draft.date = ''; draft.time = ''; draft.allDay = false; renderCalendar(); });
      none.appendChild(elements.noDeadline); none.appendChild(node('span', '', t('noDeadline'))); none.appendChild(node('small', '', t('noDeadlineHint')));
      picker.appendChild(none); renderCalendar(); return field(t('due'), picker);
    }
    function save(event) {
      event.preventDefault(); if (saving) return;
      var due = dueValue(draft);
      if (due === null) { error(t('invalidDate')); return; }
      if (draft.projectPath && draft.projectPath.charAt(0) !== '/') { error(t('invalidProject')); return; }
      if (elements.project.value === CUSTOM_PROJECT && !draft.projectPath) { error(t('invalidProject')); return; }
      saving = true; elements.fields.disabled = true; elements.save.disabled = true; elements.cancel.disabled = true;
      elements.save.textContent = t('saving'); error('');
      options.onSave({ id: item.id, projectPath: draft.projectPath, tags: draft.tags, due: due, allDay: !!due && draft.allDay, priority: draft.priority })
        .then(function () { original = JSON.stringify(draft); saving = false; close(true); })
        .catch(function (failure) {
          saving = false; elements.fields.disabled = false; elements.save.disabled = false; elements.cancel.disabled = false;
          elements.save.textContent = t('save'); error(failure.message || String(failure));
        });
    }
    function render() {
      root.textContent = ''; root.setAttribute('aria-label', t('details'));
      var header = node('div', 'detail-heading'); header.appendChild(node('h2', '', t('details')));
      header.appendChild(iconButton('x-mark', t('close'), function () { close(false); })); root.appendChild(header);
      root.appendChild(node('h3', 'detail-title', item.text));
      var form = node('form', 'detail-form'); form.addEventListener('submit', save);
      elements.fields = node('fieldset', 'detail-fields'); elements.fields.appendChild(projectField());
      elements.fields.appendChild(tagsField()); elements.fields.appendChild(dateField());
      var priority = selectControl([['', t('priorityNone')], ['urgent', t('urgent')], ['high', t('high')], ['normal', t('normal')], ['low', t('low')]], draft.priority, t('priority'), function (value) { draft.priority = value; });
      priority.id = 'detail-priority'; elements.priority = priority; elements.fields.appendChild(field(t('priority'), priority));
      form.appendChild(elements.fields); elements.error = node('p', 'detail-error hidden'); elements.error.setAttribute('role', 'alert'); form.appendChild(elements.error);
      var footer = node('div', 'detail-footer'); elements.cancel = button(t('cancel'), '', function () { close(false); });
      elements.save = button(t('save'), 'primary'); elements.save.type = 'submit'; footer.appendChild(elements.cancel); footer.appendChild(elements.save);
      elements.footer = footer; form.appendChild(footer); root.appendChild(form);
    }
    function open(nextItem, focus) {
      if (item && item.id !== nextItem.id && !confirmLeave(function () { open(nextItem, focus); options.onSelection(); })) return false;
      returnFocus = document.activeElement;
      if (!item || item.id !== nextItem.id) { item = nextItem; draft = draftFor(item); original = JSON.stringify(draft); month = parseDay(draft.date) || new Date(); render(); }
      root.classList.remove('hidden'); options.layout.classList.add('has-details'); updateLayout();
      var target = focus === 'project' ? elements.project : focus === 'tags' ? elements.tagSearch : focus === 'priority' ? elements.priority : elements.grid.querySelector('[tabindex="0"]');
      target.focus(); return true;
    }
    root.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(false); }
      if (event.key !== 'Tab' || !compact.matches) return;
      var focusable = Array.from(root.querySelectorAll('button:not(:disabled),input:not(:disabled),select:not(:disabled)')).filter(function (element) { return element.tabIndex >= 0 && element.getClientRects().length; });
      var first = focusable[0], last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    });
    return { open: open, close: close, currentId: function () { return item && item.id; },
      catalogs: function (nextProjects, nextTags) { projects = nextProjects; tags = nextTags; },
      refreshLocale: function () { if (item && !saving) render(); }
    };
  }
  window.TodoDetails = { createInspector: createInspector, renderFilters: renderFilters, icon: icon,
    button: button, tagChip: tagChip, normalizeTags: normalizeTags, dayKey: dayKey,
    parseDay: parseDay, calendarDays: calendarDays, dueValue: dueValue, draftFor: draftFor };
})();
