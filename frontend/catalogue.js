const API_URL = '../api/index.php';
const catalogueGrid = document.getElementById('catalogue-grid');
const categoryFilter = document.getElementById('category-filter');
const locationFilter = document.getElementById('location-filter');
const searchInput = document.getElementById('search-input');
const startFilter = document.getElementById('availability-start');
const endFilter = document.getElementById('availability-end');
const cart = new Map();
let catalogueItems = [];
let toastTimer;

function makeElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function imageFor(asset) {
  const path = String(asset.image_url || '');
  if (/^https:\/\//i.test(path)) return path;
  if (path && !path.startsWith('/') && !path.startsWith('#') && !path.startsWith('?') && !path.includes('\\') &&
      !/(?:^|\/)\.\.(?:\/|$)/.test(path) && !/^[a-z][a-z0-9+.-]*:/i.test(path)) return path;
  const label = `${asset.category_name || ''} ${asset.name || ''}`.toLowerCase();
  if (label.includes('fish')) return 'fishing-concentration.jpg.webp';
  if (label.includes('boat') || label.includes('marine') || label.includes('water')) return '22%20Key%20West_1.jpg.webp';
  if (label.includes('accommodation') || label.includes('hotel') || label.includes('room')) return 'bay.jpg';
  return '';
}

function imageElement(asset, className, alt) {
  const image = makeElement('img', className);
  const source = imageFor(asset);
  if (source) image.src = source;
  else {
    const escapeXml = value => String(value).replace(/[&<>"']/g, char => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;'
    })[char]);
    const category = escapeXml(asset.category_name || 'Croco Plant rental').slice(0, 40);
    const name = escapeXml(asset.name || 'Equipment').slice(0, 42);
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 600"><defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#e7ece3"/><stop offset="1" stop-color="#ccd9cd"/></linearGradient></defs><rect width="900" height="600" fill="url(#bg)"/><circle cx="720" cy="170" r="190" fill="#d8e2d4"/><path d="M0 430h900v170H0z" fill="#d4dfd3"/><g fill="none" stroke="#718977" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"><path d="M340 360h220l50 55H300z"/><path d="M390 360v-80h125l45 80"/><circle cx="365" cy="430" r="31" fill="#e7ece3"/><circle cx="565" cy="430" r="31" fill="#e7ece3"/><path d="M423 312h54m-27-30v-49"/></g><text x="54" y="500" fill="#617866" font-family="Arial,sans-serif" font-size="24" font-weight="700" letter-spacing="5">${category.toUpperCase()}</text><text x="54" y="550" fill="#153a2c" font-family="Arial,sans-serif" font-size="32" font-weight="700">${name}</text></svg>`;
    image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
    image.classList.add('image-placeholder');
  }
  image.alt = alt;
  image.loading = 'lazy';
  image.onerror = () => {
    image.onerror = null;
    image.src = 'cpf-logo-transparent.png';
    image.classList.add('image-fallback');
  };
  return image;
}

function formatRate(rate) {
  const value = Number(rate);
  if (!Number.isFinite(value) || value <= 0) return 'Rate on request';
  return `$${new Intl.NumberFormat(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value)} <small>/ day</small>`;
}

function addOptions(select, rows, idKey, labelKey, placeholder) {
  const first = select.options[0];
  select.replaceChildren(first);
  first.value = '';
  first.textContent = placeholder;
  rows.forEach(row => {
    const option = new Option(row[labelKey], row[idKey]);
    select.add(option);
  });
}

function makeCard(asset) {
  const card = makeElement('article', 'rental-card');
  const photo = makeElement('div', 'card-photo');
  photo.setAttribute('role', 'button');
  photo.setAttribute('tabindex', '0');
  photo.setAttribute('aria-label', `View details for ${asset.name}`);
  photo.append(imageElement(asset, '', asset.name));
  photo.append(makeElement('span', 'card-category', asset.category_name));
  photo.append(makeElement('span', `availability-badge${asset.available ? '' : ' unavailable'}`, asset.available ? 'Available' : 'Unavailable for dates'));
  photo.addEventListener('click', () => showDetails(asset));
  photo.addEventListener('keydown', event => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      showDetails(asset);
    }
  });

  const body = makeElement('div', 'card-body');
  body.append(makeElement('p', 'card-location', asset.location_name));
  body.append(makeElement('h3', 'card-title', asset.name));
  body.append(makeElement('p', 'card-description', asset.description || `${asset.name} is available to request from Croco Plant. Contact our team to confirm specifications and hire details.`));
  const meta = makeElement('div', 'card-meta');
  const rate = makeElement('p', Number(asset.daily_rate) > 0 ? 'rate' : 'rate-on-request');
  if (Number(asset.daily_rate) > 0) rate.innerHTML = formatRate(asset.daily_rate);
  else rate.textContent = 'Rate on request';
  const actions = makeElement('div', 'card-actions');
  const details = makeElement('button', 'text-button', 'Details');
  details.type = 'button';
  details.addEventListener('click', () => showDetails(asset));
  const add = makeElement('button', 'add-button', cart.has(Number(asset.asset_id)) ? 'Added' : 'Add to list');
  add.type = 'button';
  add.disabled = !asset.available || cart.has(Number(asset.asset_id));
  add.addEventListener('click', () => addToCart(asset));
  actions.append(details, add);
  meta.append(rate, actions);
  body.append(meta);
  card.append(photo, body);
  return card;
}

function renderCatalogue(items) {
  catalogueItems = items;
  catalogueGrid.replaceChildren(...items.map(makeCard));
  document.getElementById('catalogue-count').textContent = `${items.length} ${items.length === 1 ? 'rental' : 'rentals'}`;
  document.getElementById('empty-state').hidden = items.length > 0;
  document.getElementById('load-error').hidden = true;
}

async function loadCatalogue() {
  const error = document.getElementById('load-error');
  const params = new URLSearchParams({ resource: 'catalog' });
  const search = searchInput.value.trim();
  if (search) params.set('search', search);
  if (categoryFilter.value) params.set('category_id', categoryFilter.value);
  if (locationFilter.value) params.set('location_id', locationFilter.value);
  if (startFilter.value && endFilter.value) {
    params.set('start_date', startFilter.value);
    params.set('end_date', endFilter.value);
  }
  error.hidden = true;
  catalogueGrid.replaceChildren(makeElement('p', 'loading-message', 'Loading rentals…'));
  try {
    const response = await fetch(`${API_URL}?${params.toString()}`, { headers: { Accept: 'application/json' } });
    const result = await response.json();
    if (!response.ok || !result.success) throw new Error(result.message || `Catalogue could not be loaded (${response.status}).`);
    addOptions(categoryFilter, result.categories || [], 'category_id', 'category_name', 'All categories');
    addOptions(locationFilter, result.locations || [], 'location_id', 'location_name', 'All locations');
    categoryFilter.value = params.get('category_id') || '';
    locationFilter.value = params.get('location_id') || '';
    renderCatalogue(Array.isArray(result.data) ? result.data : []);
  } catch (errorValue) {
    console.error('Catalogue loading failed:', errorValue);
    catalogueGrid.replaceChildren();
    error.textContent = `${errorValue.message} Please try again or contact Croco Plant.`;
    error.hidden = false;
    document.getElementById('catalogue-count').textContent = '';
  }
}

function renderDetails(asset) {
  const root = document.getElementById('details-content');
  root.replaceChildren();
  root.append(imageElement(asset, 'details-photo', asset.name));
  const copy = makeElement('div', 'details-copy');
  copy.append(makeElement('p', 'eyebrow eyebrow-dark', asset.category_name));
  copy.append(makeElement('h2', '', asset.name));
  copy.append(makeElement('p', 'details-location', `${asset.location_name} · ${asset.available ? 'Available for selected dates' : 'Unavailable for selected dates'}`));
  copy.append(makeElement('p', '', asset.description || `${asset.name} is listed for hire by Croco Plant. Contact our team to confirm specifications and hire details.`));
  const list = makeElement('ul', 'details-list');
  [
    ['Category', asset.category_name],
    ['Location', asset.location_name],
    ['Condition', asset.condition ? asset.condition[0].toUpperCase() + asset.condition.slice(1) : 'Contact Croco Plant'],
    ['Availability', asset.available ? 'Requestable' : 'Not available for selected dates']
  ].forEach(([label, value]) => {
    const row = makeElement('li');
    row.append(makeElement('span', '', label), makeElement('b', '', value));
    list.append(row);
  });
  const specifications = asset.specifications && typeof asset.specifications === 'object' ? Object.entries(asset.specifications) : [];
  specifications.forEach(([label, value]) => {
    const row = makeElement('li');
    row.append(makeElement('span', '', label), makeElement('b', '', String(value)));
    list.append(row);
  });
  copy.append(list);
  if (asset.rental_terms) copy.append(makeElement('p', '', asset.rental_terms));
  const rate = makeElement('p', Number(asset.daily_rate) > 0 ? 'rate' : 'rate-on-request');
  if (Number(asset.daily_rate) > 0) rate.innerHTML = formatRate(asset.daily_rate);
  else rate.textContent = 'Rate on request';
  const add = makeElement('button', 'button button-green button-full', cart.has(Number(asset.asset_id)) ? 'Already in your list' : 'Add to request list');
  add.type = 'button';
  add.disabled = !asset.available || cart.has(Number(asset.asset_id));
  add.addEventListener('click', () => {
    addToCart(asset);
    closeDetails();
  });
  copy.append(rate, add);
  root.append(copy);
}

function showDetails(asset) {
  renderDetails(asset);
  document.getElementById('details-backdrop').hidden = false;
  const modal = document.getElementById('details-modal');
  modal.classList.add('open');
  modal.setAttribute('aria-hidden', 'false');
  document.body.classList.add('locked');
  modal.querySelector('[data-close-details]').focus();
}

function closeDetails() {
  const modal = document.getElementById('details-modal');
  modal.classList.remove('open');
  modal.setAttribute('aria-hidden', 'true');
  document.getElementById('details-backdrop').hidden = true;
  unlockIfClosed();
}

function addToCart(asset) {
  if (!asset.available) return;
  cart.set(Number(asset.asset_id), asset);
  renderCatalogue(catalogueItems);
  renderCart();
  showToast(`${asset.name} added to your request list.`);
}

function removeFromCart(assetId) {
  cart.delete(Number(assetId));
  renderCatalogue(catalogueItems);
  renderCart();
}

function renderCart() {
  const items = [...cart.values()];
  const container = document.getElementById('cart-items');
  container.replaceChildren();
  document.getElementById('cart-count').textContent = String(items.length);
  document.getElementById('cart-empty').hidden = items.length > 0;
  document.getElementById('continue-request').disabled = items.length === 0;
  items.forEach(asset => {
    const row = makeElement('article', 'cart-item');
    row.append(imageElement(asset, '', asset.name));
    const copy = makeElement('div');
    copy.append(makeElement('h3', '', asset.name), makeElement('p', '', `${asset.category_name} · ${asset.location_name}`));
    const remove = makeElement('button', 'remove-item', 'Remove');
    remove.type = 'button';
    remove.setAttribute('aria-label', `Remove ${asset.name} from request list`);
    remove.addEventListener('click', () => removeFromCart(asset.asset_id));
    row.append(copy, remove);
    container.append(row);
  });
  document.getElementById('request-summary').textContent = items.length
    ? `${items.length} selected: ${items.map(asset => asset.name).join(', ')}`
    : 'Your request list is empty.';
}

function updateDuration() {
  const start = document.getElementById('request-start').value;
  const end = document.getElementById('request-end').value;
  const summary = document.getElementById('duration-summary');
  if (!start || !end) {
    summary.textContent = 'Choose dates to see the rental duration.';
    return;
  }
  if (end < start) {
    summary.textContent = 'End date must be on or after the start date.';
    return;
  }
  const toUtc = value => {
    const [year, month, day] = value.split('-').map(Number);
    return Date.UTC(year, month - 1, day);
  };
  const days = Math.round((toUtc(end) - toUtc(start)) / 86400000) + 1;
  summary.textContent = `Rental duration: ${days} ${days === 1 ? 'day' : 'days'}. Croco Plant will confirm the final hire period.`;
}

function openCart() {
  const panel = document.getElementById('cart-panel');
  panel.classList.add('open');
  panel.setAttribute('aria-hidden', 'false');
  document.getElementById('drawer-backdrop').hidden = false;
  document.getElementById('open-cart').setAttribute('aria-expanded', 'true');
  document.body.classList.add('locked');
  document.getElementById('close-cart').focus();
}

function closeCart() {
  const panel = document.getElementById('cart-panel');
  panel.classList.remove('open');
  panel.setAttribute('aria-hidden', 'true');
  document.getElementById('drawer-backdrop').hidden = true;
  document.getElementById('open-cart').setAttribute('aria-expanded', 'false');
  unlockIfClosed();
}

function openRequest() {
  if (!cart.size) return;
  closeCart();
  document.getElementById('request-message').textContent = '';
  document.getElementById('request-backdrop').hidden = false;
  const modal = document.getElementById('request-modal');
  modal.classList.add('open');
  modal.setAttribute('aria-hidden', 'false');
  document.body.classList.add('locked');
  const form = document.getElementById('request-form');
  if (startFilter.value) form.elements.start_date.value = startFilter.value;
  if (endFilter.value) form.elements.end_date.value = endFilter.value;
  updateDuration();
  modal.querySelector('input[name="name"]').focus();
}

function closeRequest() {
  const modal = document.getElementById('request-modal');
  modal.classList.remove('open');
  modal.setAttribute('aria-hidden', 'true');
  document.getElementById('request-backdrop').hidden = true;
  unlockIfClosed();
}

function unlockIfClosed() {
  const open = document.querySelector('.cart-panel.open, .details-modal.open, .request-modal.open');
  if (!open) document.body.classList.remove('locked');
}

function showToast(message) {
  const toast = document.getElementById('toast');
  if (!toast) {
    console.info(message);
    return;
  }
  toast.textContent = message;
  toast.classList.add('show');
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove('show'), 2800);
}

function validateFilterDates() {
  const message = document.getElementById('filter-message');
  if ((startFilter.value === '') !== (endFilter.value === '')) {
    message.textContent = 'Choose both dates to check availability for a rental period.';
    return false;
  }
  if (startFilter.value && endFilter.value && endFilter.value < startFilter.value) {
    message.textContent = 'End date must be on or after the start date.';
    return false;
  }
  if (startFilter.value && startFilter.value < localDateString()) {
    message.textContent = 'Choose a start date of today or later.';
    return false;
  }
  message.textContent = '';
  return true;
}

let searchTimer;
function localDateString(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

if (catalogueGrid && searchInput) {
  searchInput.addEventListener('input', () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => {
      if (validateFilterDates()) loadCatalogue();
    }, 250);
  });
  categoryFilter.addEventListener('change', () => { if (validateFilterDates()) loadCatalogue(); });
  locationFilter.addEventListener('change', () => { if (validateFilterDates()) loadCatalogue(); });
  [startFilter, endFilter].forEach(input => input.addEventListener('change', () => {
    if (validateFilterDates()) loadCatalogue();
  }));
  document.getElementById('filter-form').addEventListener('submit', event => {
    event.preventDefault();
    if (validateFilterDates()) loadCatalogue();
  });
  document.getElementById('clear-filters').addEventListener('click', () => {
    searchInput.value = '';
    categoryFilter.value = '';
    locationFilter.value = '';
    startFilter.value = '';
    endFilter.value = '';
    document.getElementById('filter-message').textContent = '';
    loadCatalogue();
  });
  document.getElementById('open-cart').addEventListener('click', openCart);
  document.getElementById('close-cart').addEventListener('click', closeCart);
  document.getElementById('drawer-backdrop').addEventListener('click', closeCart);
  document.getElementById('browse-from-cart').addEventListener('click', closeCart);
  document.getElementById('continue-request').addEventListener('click', openRequest);
  document.getElementById('details-backdrop').addEventListener('click', closeDetails);
  document.querySelectorAll('[data-close-details]').forEach(button => button.addEventListener('click', closeDetails));
  document.getElementById('request-backdrop').addEventListener('click', closeRequest);
  document.querySelectorAll('[data-close-request]').forEach(button => button.addEventListener('click', closeRequest));
  ['request-start', 'request-end'].forEach(id => document.getElementById(id).addEventListener('change', updateDuration));
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    closeDetails();
    closeRequest();
    closeCart();
  });

  document.getElementById('request-form').addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.currentTarget;
    const message = document.getElementById('request-message');
    const submit = document.getElementById('submit-request');
    message.textContent = '';
    if (!cart.size) {
      message.textContent = 'Add at least one item before sending a request.';
      return;
    }
    if (form.elements.end_date.value < form.elements.start_date.value) {
      message.textContent = 'End date must be on or after the start date.';
      return;
    }
    submit.disabled = true;
    submit.textContent = 'Sending request…';
    const payload = {
      name: form.elements.name.value.trim(),
      email: form.elements.email.value.trim(),
      phone: form.elements.phone.value.trim(),
      start_date: form.elements.start_date.value,
      end_date: form.elements.end_date.value,
      requirements: form.elements.requirements.value.trim(),
      items: [...cart.keys()].map(asset_id => ({ asset_id }))
    };
    try {
      const response = await fetch(`${API_URL}?resource=rental-requests`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(payload)
      });
      const result = await response.json();
      if (!response.ok || !result.success) throw new Error(result.message || `Request could not be sent (${response.status}).`);
      const requestId = result.request_id ? ` Reference #${result.request_id}.` : '';
      cart.clear();
      form.reset();
      renderCart();
      closeRequest();
      await loadCatalogue();
      showToast(`Your request was sent to Croco Plant.${requestId}`);
    } catch (error) {
      console.error('Rental request submission failed:', error);
      message.textContent = error.message || 'Unable to send the request. Please try again.';
    } finally {
      submit.disabled = false;
      submit.innerHTML = 'Send rental request <span aria-hidden="true">→</span>';
    }
  });

  renderCart();
  loadCatalogue();
}

const enquiryForm = document.querySelector('.enquiry-form');
if (enquiryForm) {
  enquiryForm.addEventListener('submit', event => {
    event.preventDefault();
    const form = event.currentTarget;
    const values = new FormData(form);
    const subject = `Croco Plant website enquiry from ${values.get('name')}`;
    const body = [
      `Name: ${values.get('name')}`,
      `Email: ${values.get('email')}`,
      `Company: ${values.get('company') || 'Not provided'}`,
      `Phone: ${values.get('phone') || 'Not provided'}`,
      '',
      'Enquiry:',
      values.get('message')
    ].join('\n');
    const feedback = document.getElementById('enquiry-feedback');
    feedback.textContent = 'Your email app should open with this enquiry. Send the draft to complete your message.';
    window.location.href = `mailto:info@crocoplant.co.zw?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
  });
}

const currentYear = document.getElementById('current-year');
if (currentYear) currentYear.textContent = String(new Date().getFullYear());

const today = localDateString();
['availability-start', 'availability-end', 'request-start', 'request-end'].forEach(id => {
  const element = document.getElementById(id);
  if (element) element.min = today;
});
