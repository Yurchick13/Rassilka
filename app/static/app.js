(function () {
  const body = document.body;
  if (!body) return;

  const page = body.dataset.page || "";
  const apiBase = body.dataset.apiBase || "/api";
  const wsPath = body.dataset.wsPath || "/ws/registry";
  const canEdit = body.dataset.canEdit === "true";
  const canFullEdit = body.dataset.canFullEdit === "true";
  const canDelete = body.dataset.canDelete === "true";

  const wsProtocol = window.location.protocol === "https:" ? "wss" : "ws";
  const wsUrl = `${wsProtocol}://${window.location.host}${wsPath}`;
  const AUTO_REFRESH_MS = 60000;
  const ACTIVE_STATUSES = new Set(["В отпуске", "Больничный лист"]);
  const VALIDATION_FIELD_LABELS = {
    username: "Логин",
    password: "Пароль",
    current_password: "Текущий пароль",
    new_password: "Новый пароль",
    new_password_confirm: "Подтверждение нового пароля",
    employee_full_name: "ФИО сотрудника",
    is_special_employee: "Особый сотрудник",
    employee_positions: "Должность/должности",
    status: "Статус",
    service: "Услуга",
    deputies: "Заместители",
    vacation_position: "Должность в отпуске",
    deputy_full_name: "ФИО заместителя",
    deputy_actual_position: "Фактическая должность заместителя",
    start_date: "Дата начала отпуска",
    end_date: "Дата окончания отпуска",
    memo: "Памятка",
    role: "Роль",
    period_from: "Период с",
    period_to: "Период по",
    include_finished: "Показывать завершенные",
    file: "Файл",
  };

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function isActiveStatus(value) {
    return ACTIVE_STATUSES.has(String(value || "").trim());
  }

  function parsePositions(raw) {
    return String(raw || "")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
  }

  function positionsToMultiline(positions) {
    return asArray(positions).join("\n");
  }

  function formatDate(dateIso) {
    if (!dateIso) return "—";
    try {
      const date = new Date(`${dateIso}T00:00:00`);
      return new Intl.DateTimeFormat("ru-RU").format(date);
    } catch {
      return dateIso;
    }
  }

  function formatLocalDateTime(date) {
    return new Intl.DateTimeFormat("ru-RU", {
      dateStyle: "short",
      timeStyle: "medium",
    }).format(date);
  }

  function daysUntil(dateIso) {
    const target = new Date(`${dateIso}T00:00:00`);
    const now = new Date();
    now.setHours(0, 0, 0, 0);
    return Math.round((target.getTime() - now.getTime()) / 86400000);
  }

  function setStatus(elementId, message, kind) {
    const el = document.getElementById(elementId);
    if (!el) return;

    const safeKind = kind || "info";
    el.textContent = message || "";
    el.classList.remove("status-muted", "status-info", "status-success", "status-error");
    el.classList.add(`status-${safeKind}`);
  }

  function showToast(message, kind) {
    const type = kind || "info";
    let stack = document.querySelector(".toast-stack");
    if (!stack) {
      stack = document.createElement("div");
      stack.className = "toast-stack";
      document.body.appendChild(stack);
    }

    const toast = document.createElement("div");
    toast.className = `toast ${type}`;
    toast.textContent = message;
    stack.appendChild(toast);

    window.setTimeout(() => {
      toast.remove();
      if (stack && stack.children.length === 0) {
        stack.remove();
      }
    }, 4500);
  }

  function setButtonBusy(button, isBusy, busyText) {
    if (!button) return;
    if (!button.dataset.defaultText) {
      button.dataset.defaultText = button.textContent || "";
    }
    button.disabled = isBusy;
    button.classList.toggle("is-busy", isBusy);
    button.textContent = isBusy ? busyText : button.dataset.defaultText;
  }

  function pluralizeRu(value, one, few, many) {
    const n = Math.abs(Number(value) || 0) % 100;
    const n1 = n % 10;
    if (n > 10 && n < 20) return many;
    if (n1 > 1 && n1 < 5) return few;
    if (n1 === 1) return one;
    return many;
  }

  function mapFieldKeyToLabel(key) {
    return VALIDATION_FIELD_LABELS[key] || key;
  }

  function normalizeValidationMsg(item) {
    const type = String(item?.type || "");
    const ctx = item?.ctx || {};
    const raw = String(item?.msg || "").trim();

    if (type === "missing") return "обязательное поле не заполнено";
    if (type === "string_too_short" && ctx.min_length != null) {
      const min = Number(ctx.min_length);
      return `слишком короткое значение, минимум ${min} ${pluralizeRu(min, "символ", "символа", "символов")}`;
    }
    if (type === "string_too_long" && ctx.max_length != null) {
      const max = Number(ctx.max_length);
      return `слишком длинное значение, максимум ${max} ${pluralizeRu(max, "символ", "символа", "символов")}`;
    }
    if (type.includes("date")) return "некорректная дата";
    if (type.includes("list")) return "ожидается список значений";
    if (type.includes("string_type")) return "ожидается текстовое значение";
    if (type.includes("int_parsing") || type.includes("int_type")) return "ожидается целое число";
    if (type.includes("bool")) return "ожидается значение Да/Нет";

    const valueErrorPrefix = /^Value error,\s*/i;
    const cleaned = raw.replace(valueErrorPrefix, "");
    if (/Field required/i.test(cleaned)) return "обязательное поле не заполнено";

    const shortMatch = cleaned.match(/String should have at least (\d+) characters?/i);
    if (shortMatch) {
      const min = Number(shortMatch[1]);
      return `слишком короткое значение, минимум ${min} ${pluralizeRu(min, "символ", "символа", "символов")}`;
    }

    const longMatch = cleaned.match(/String should have at most (\d+) characters?/i);
    if (longMatch) {
      const max = Number(longMatch[1]);
      return `слишком длинное значение, максимум ${max} ${pluralizeRu(max, "символ", "символа", "символов")}`;
    }

    return cleaned || "некорректное значение";
  }

  function formatValidationLocation(loc) {
    if (!Array.isArray(loc) || !loc.length) return "";
    const parts = loc.filter((part) => !["body", "query", "path", "response"].includes(String(part)));
    if (!parts.length) return "";

    const rendered = [];
    let i = 0;
    while (i < parts.length) {
      const part = parts[i];

      if (part === "deputies" && typeof parts[i + 1] === "number") {
        const idx = Number(parts[i + 1]) + 1;
        const nestedKey = parts[i + 2];
        if (typeof nestedKey === "string") {
          rendered.push(`Заместитель #${idx} (${mapFieldKeyToLabel(nestedKey)})`);
          i += 3;
          continue;
        }
        rendered.push(`Заместитель #${idx}`);
        i += 2;
        continue;
      }

      if (typeof part === "number") {
        rendered.push(`#${part + 1}`);
      } else {
        rendered.push(mapFieldKeyToLabel(String(part)));
      }
      i += 1;
    }

    return rendered.join(" -> ");
  }

  function formatErrorMessage(data, fallbackText) {
    if (!data) return fallbackText;
    if (typeof data.detail === "string" && data.detail.trim()) return data.detail;
    if (Array.isArray(data.detail) && data.detail.length) {
      const details = data.detail
        .map((item) => {
          if (typeof item === "string") return item;
          if (item && typeof item.msg === "string") {
            const label = formatValidationLocation(item.loc);
            const message = normalizeValidationMsg(item);
            return label ? `${label}: ${message}` : message;
          }
          return "";
        })
        .filter(Boolean)
        .map((line) => `- ${line}`);
      if (details.length) return details.join("\n");
    }
    return fallbackText;
  }

  async function parseResponseError(response, fallbackText) {
    if (response.status === 401) {
      window.location.href = "/login";
      throw new Error("Требуется вход в систему.");
    }

    const text = await response.text().catch(() => "");
    if (!text) {
      throw new Error(fallbackText);
    }

    let data = null;
    try {
      data = JSON.parse(text);
    } catch {
      data = null;
    }

    if (data) {
      throw new Error(formatErrorMessage(data, fallbackText));
    }

    throw new Error(text || fallbackText);
  }

  function validateDateRange(startDate, endDate) {
    if (!startDate || !endDate) return;
    if (endDate < startDate) {
      throw new Error("Дата окончания отпуска не может быть раньше даты начала.");
    }
  }

  function createDeputyRow(templateId, values) {
    const template = document.getElementById(templateId);
    if (!template) return null;

    const row = template.content.firstElementChild.cloneNode(true);
    const data = values || {};

    const vacationPositionInput = row.querySelector('[name="vacation_position"]');
    const deputyFullNameInput = row.querySelector('[name="deputy_full_name"]');
    const deputyActualPositionInput = row.querySelector('[name="deputy_actual_position"]');

    if (vacationPositionInput) vacationPositionInput.value = data.vacation_position || "";
    if (deputyFullNameInput) deputyFullNameInput.value = data.deputy_full_name || "";
    if (deputyActualPositionInput) deputyActualPositionInput.value = data.deputy_actual_position || "";

    const removeButton = row.querySelector(".remove-deputy");
    removeButton?.addEventListener("click", () => row.remove());

    return row;
  }

  function collectDeputies(container) {
    const rows = container ? container.querySelectorAll(".deputy-row") : [];
    const deputies = [];

    rows.forEach((row) => {
      const vacationPosition = row.querySelector('[name="vacation_position"]')?.value.trim() || "";
      const deputyFullName = row.querySelector('[name="deputy_full_name"]')?.value.trim() || "";
      const deputyActualPosition = row.querySelector('[name="deputy_actual_position"]')?.value.trim() || "";

      const anyFilled = vacationPosition || deputyFullName || deputyActualPosition;
      const allFilled = vacationPosition && deputyFullName && deputyActualPosition;

      if (anyFilled && !allFilled) {
        throw new Error("Заполните все три поля для каждого заместителя.");
      }

      if (allFilled) {
        deputies.push({
          vacation_position: vacationPosition,
          deputy_full_name: deputyFullName,
          deputy_actual_position: deputyActualPosition,
        });
      }
    });

    if (!deputies.length) {
      throw new Error("Добавьте хотя бы одного заместителя.");
    }

    return deputies;
  }

  function buildVacationPayload(form, deputiesContainer) {
    const employeePositions = parsePositions(form.employee_positions.value);
    if (!employeePositions.length) {
      throw new Error("Укажите хотя бы одну должность сотрудника.");
    }

    const startDate = form.start_date.value;
    const endDate = form.end_date.value;
    validateDateRange(startDate, endDate);

    return {
      employee_full_name: form.employee_full_name.value.trim(),
      is_special_employee: form.is_special_employee?.checked === true,
      employee_positions: employeePositions,
      status: form.status.value,
      service: form.service.value.trim(),
      deputies: collectDeputies(deputiesContainer),
      memo: form.memo.value.trim() || null,
      start_date: startDate,
      end_date: endDate,
    };
  }

  async function createVacation(payload) {
    const response = await fetch(`${apiBase}/vacations`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      await parseResponseError(response, "Не удалось сохранить запись.");
    }

    return response.json();
  }

  async function importVacationsExcel(file) {
    const formData = new FormData();
    formData.append("file", file);

    const response = await fetch(`${apiBase}/vacations/import`, {
      method: "POST",
      body: formData,
    });

    if (!response.ok) {
      await parseResponseError(response, "Не удалось импортировать Excel.");
    }

    return response.json();
  }

  async function updateVacation(recordId, payload) {
    const response = await fetch(`${apiBase}/vacations/${recordId}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      await parseResponseError(response, "Не удалось обновить запись.");
    }

    return response.json();
  }

  async function archiveVacation(recordId) {
    const response = await fetch(`${apiBase}/vacations/${recordId}`, {
      method: "DELETE",
    });

    if (!response.ok) {
      await parseResponseError(response, "Не удалось завершить запись отпуска.");
    }
  }

  async function hardDeleteVacation(recordId) {
    const response = await fetch(`${apiBase}/vacations/${recordId}/hard`, {
      method: "DELETE",
    });

    if (!response.ok) {
      await parseResponseError(response, "Не удалось полностью удалить запись.");
    }
  }

  async function loadActiveVacations() {
    const response = await fetch(`${apiBase}/vacations`);
    if (!response.ok) {
      await parseResponseError(response, "Не удалось загрузить таблицу отпусков.");
    }
    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  }

  async function loadPublicVacations(tab) {
    const safeTab = tab === "finished" ? "finished" : "current";
    const response = await fetch(`${apiBase}/vacations?tab=${encodeURIComponent(safeTab)}`);
    if (!response.ok) {
      await parseResponseError(response, "Не удалось загрузить данные клиентской таблицы.");
    }
    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  }

  function buildPublicExportUrl(tab) {
    const safeTab = tab === "finished" ? "finished" : "current";
    return `${apiBase}/vacations/export?tab=${encodeURIComponent(safeTab)}`;
  }

  async function loadPlannedVacations(filters) {
    const params = new URLSearchParams();
    if (filters.employeeFullName) params.set("employee_full_name", filters.employeeFullName);
    if (filters.service) params.set("service", filters.service);
    if (filters.periodFrom) params.set("period_from", filters.periodFrom);
    if (filters.periodTo) params.set("period_to", filters.periodTo);
    params.set("include_finished", filters.includeFinished ? "true" : "false");

    const response = await fetch(`${apiBase}/plans?${params.toString()}`);
    if (!response.ok) {
      await parseResponseError(response, "Не удалось загрузить план отпусков.");
    }

    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  }

  function buildPlansExportUrl(filters) {
    const params = new URLSearchParams();
    if (filters.employeeFullName) params.set("employee_full_name", filters.employeeFullName);
    if (filters.service) params.set("service", filters.service);
    if (filters.periodFrom) params.set("period_from", filters.periodFrom);
    if (filters.periodTo) params.set("period_to", filters.periodTo);
    params.set("include_finished", filters.includeFinished ? "true" : "false");
    return `${apiBase}/plans/export?${params.toString()}`;
  }

  async function loadSyncLogs(limit) {
    const response = await fetch(`${apiBase}/sync-logs?limit=${encodeURIComponent(String(limit || 50))}`);
    if (!response.ok) {
      await parseResponseError(response, "Не удалось загрузить журнал изменений.");
    }
    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  }

  async function loadAdminClientHeartbeats() {
    const response = await fetch(`${apiBase}/client-heartbeats`);
    if (!response.ok) {
      await parseResponseError(response, "Не удалось загрузить монитор клиентов.");
    }
    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  }

  async function applyPlanTodayNow() {
    const response = await fetch(`${apiBase}/maintenance/apply-today`, {
      method: "POST",
    });
    if (!response.ok) {
      await parseResponseError(response, "Не удалось применить план на сегодня.");
    }
    return response.json();
  }

  function connectWebSocket(onRegistryUpdated, onConnectionChanged) {
    let ws = null;
    let reconnectTimer = null;
    let pingTimer = null;
    let closedByUser = false;

    function clearTimers() {
      if (reconnectTimer) {
        window.clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      if (pingTimer) {
        window.clearInterval(pingTimer);
        pingTimer = null;
      }
    }

    function connect() {
      if (closedByUser) return;
      ws = new WebSocket(wsUrl);

      ws.onopen = function () {
        onConnectionChanged?.(true);
        pingTimer = window.setInterval(() => {
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send("ping");
          }
        }, 20000);
      };

      ws.onmessage = function (event) {
        let payload;
        try {
          payload = JSON.parse(event.data);
        } catch {
          return;
        }

        if (payload?.type === "registry_updated") {
          onRegistryUpdated?.(payload);
        }
      };

      ws.onclose = function () {
        onConnectionChanged?.(false);
        clearTimers();
        if (!closedByUser) {
          reconnectTimer = window.setTimeout(connect, 2000);
        }
      };

      ws.onerror = function () {
        onConnectionChanged?.(false);
      };
    }

    connect();

    return function disconnect() {
      closedByUser = true;
      clearTimers();
      if (ws && ws.readyState !== WebSocket.CLOSED) {
        try {
          ws.close();
        } catch {
          /* no-op */
        }
      }
    };
  }

  function renderDeputies(deputies) {
    const list = asArray(deputies);
    if (!list.length) return "—";
    return list
      .map(
        (item) =>
          `${escapeHtml(item.vacation_position)} -> ${escapeHtml(item.deputy_full_name)} ` +
          `(${escapeHtml(item.deputy_actual_position)})`
      )
      .join("<br>");
  }

  function renderEmployeeCell(item) {
    const employeeName = escapeHtml(item?.employee_full_name || "—");
    if (!item?.is_special_employee) {
      return employeeName;
    }
    return `${employeeName}<br><span class="special-badge">Особый сотрудник</span>`;
  }

  function buildSearchText(item) {
    return [
      item.employee_full_name,
      item.is_special_employee ? "особый сотрудник" : "",
      asArray(item.employee_positions).join(" "),
      item.status,
      item.service,
      item.memo || "",
      item.start_date,
      item.end_date,
      asArray(item.deputies)
        .map((dep) => `${dep.vacation_position} ${dep.deputy_full_name} ${dep.deputy_actual_position}`)
        .join(" "),
    ]
      .join(" ")
      .toLowerCase();
  }

  function initIndexPage() {
    const form = document.getElementById("vacation-form");
    const submitButton = document.getElementById("save-vacation-btn");
    const resetButton = document.getElementById("reset-vacation-form");
    const addDeputyButton = document.getElementById("add-deputy");
    const deputiesList = document.getElementById("deputies-list");
    const importForm = document.getElementById("excel-import-form");
    const importFileInput = document.getElementById("excel-import-file");
    const importButton = document.getElementById("import-excel-btn");

    if (!form || !submitButton || !addDeputyButton || !deputiesList) return;

    function ensureOneDeputyRow() {
      if (deputiesList.children.length > 0) return;
      const row = createDeputyRow("deputy-row-template", {});
      if (row) deputiesList.appendChild(row);
    }

    function resetFormState() {
      form.reset();
      deputiesList.innerHTML = "";
      ensureOneDeputyRow();
      setStatus("form-message", "Форма очищена. Можно вводить новую запись.", "muted");
    }

    ensureOneDeputyRow();

    addDeputyButton.addEventListener("click", () => {
      const row = createDeputyRow("deputy-row-template", {});
      if (row) deputiesList.appendChild(row);
    });

    resetButton?.addEventListener("click", resetFormState);

    form.addEventListener("submit", async (event) => {
      event.preventDefault();

      try {
        setButtonBusy(submitButton, true, "Сохранение...");
        const payload = buildVacationPayload(form, deputiesList);
        await createVacation(payload);

        form.reset();
        deputiesList.innerHTML = "";
        ensureOneDeputyRow();

        setStatus("form-message", "Запись сохранена. Уведомления отправлены клиентским приложениям.", "success");
        showToast("Реестр обновлен, уведомления отправлены.", "success");
      } catch (error) {
        setStatus("form-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(submitButton, false);
      }
    });

    importForm?.addEventListener("submit", async (event) => {
      event.preventDefault();

      try {
        const files = importFileInput?.files;
        if (!files || files.length === 0) {
          throw new Error("Выберите Excel-файл для загрузки.");
        }

        const file = files[0];
        if (!file.name.toLowerCase().endsWith(".xlsx")) {
          throw new Error("Поддерживается только формат .xlsx");
        }

        setButtonBusy(importButton, true, "Импорт...");
        setStatus("import-message", "Идет обработка Excel-файла...", "muted");

        const result = await importVacationsExcel(file);
        const errorsPreview = Array.isArray(result.errors) && result.errors.length
          ? ` Ошибки: ${result.errors.slice(0, 3).join(" | ")}`
          : "";
        const updated = Number(result.updated_count || 0);
        const archived = Number(result.reconciled_archived_count || 0);
        const removed = Number(result.reconciled_deleted_count || 0);

        setStatus(
          "import-message",
          `Импорт завершен. Создано: ${result.created_count}, обновлено: ${updated}, закрыто: ${archived}, удалено будущих: ${removed}, дублей в файле: ${result.duplicate_count}, пустых строк: ${result.skipped_empty_rows}, ошибок: ${result.error_count}.${errorsPreview}`,
          result.error_count > 0 ? "info" : "success"
        );
        showToast("Импорт Excel завершен.", result.error_count > 0 ? "info" : "success");
        importForm.reset();
      } catch (error) {
        setStatus("import-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(importButton, false);
      }
    });
  }

  function initActivePage() {
    const refreshButton = document.getElementById("refresh-active");
    const searchInput = document.getElementById("active-search");
    const clearSearchButton = document.getElementById("clear-active-search");
    const tbody = document.querySelector("#active-table tbody");
    const wsState = document.getElementById("ws-state");
    const lastSync = document.getElementById("active-last-sync");
    const visibleCountEl = document.getElementById("active-visible-count");
    const totalCountEl = document.getElementById("active-total-count");
    const endingSoonEl = document.getElementById("active-ending-soon");
    const noMemoEl = document.getElementById("active-no-memo");

    const modal = document.getElementById("edit-modal");
    const editForm = document.getElementById("edit-vacation-form");
    const editDeputiesList = document.getElementById("edit-deputies-list");
    const addEditDeputyButton = document.getElementById("add-edit-deputy");
    const closeEditModalButton = document.getElementById("close-edit-modal");
    const cancelEditButton = document.getElementById("cancel-edit-btn");
    const saveEditButton = document.getElementById("save-edit-btn");

    if (!tbody) return;

    const state = {
      allRows: [],
      filteredRows: [],
      query: "",
      byId: new Map(),
      wsDisconnect: null,
    };

    function setWsState(isConnected) {
      if (!wsState) return;
      wsState.textContent = isConnected ? "Онлайн" : "Нет связи";
      wsState.style.color = isConnected ? "#136640" : "#8b1f17";
    }

    function updateCounters() {
      const allRows = state.allRows;
      const visibleRows = state.filteredRows;

      const endingSoon = allRows.filter((item) => {
        const d = daysUntil(item.end_date);
        return d >= 0 && d <= 2;
      }).length;

      const noMemo = allRows.filter((item) => !String(item.memo || "").trim()).length;

      if (visibleCountEl) visibleCountEl.textContent = String(visibleRows.length);
      if (totalCountEl) totalCountEl.textContent = String(allRows.length);
      if (endingSoonEl) endingSoonEl.textContent = String(endingSoon);
      if (noMemoEl) noMemoEl.textContent = String(noMemo);
    }

    function renderRows(rows) {
      tbody.innerHTML = "";

      if (!rows.length) {
        const tr = document.createElement("tr");
        tr.innerHTML = '<td colspan="8" class="empty-cell">Записей по текущему фильтру нет.</td>';
        tbody.appendChild(tr);
        return;
      }

      rows.forEach((item) => {
        const positionsHtml = asArray(item.employee_positions).map(escapeHtml).join("<br>") || "—";
        const memo = item.memo ? escapeHtml(item.memo) : "—";
        const daysLeft = daysUntil(item.end_date);

        const periodText = `${escapeHtml(formatDate(item.start_date))} — ${escapeHtml(formatDate(item.end_date))}`;
        const daysText = daysLeft >= 0 ? `До окончания: ${daysLeft} дн.` : "Срок уже завершен";

        const actionHtml = canEdit
          ? `
            <div class="table-actions">
              <button type="button" class="button compact secondary" data-action="edit" data-id="${item.id}">
                Редактировать
              </button>
              ${canFullEdit ? `<button type="button" class="button compact danger" data-action="archive" data-id="${item.id}">Завершить</button>` : ""}
              ${canDelete ? `<button type="button" class="button compact danger outline" data-action="hard-delete" data-id="${item.id}">Удалить</button>` : ""}
            </div>
          `
          : "—";

        const tr = document.createElement("tr");
        if (daysLeft < 0) {
          tr.classList.add("row-overdue");
        } else if (daysLeft <= 2) {
          tr.classList.add("row-soon");
        }
        if (item.is_special_employee) {
          tr.classList.add("row-special");
        }

        tr.innerHTML = `
          <td>${renderEmployeeCell(item)}</td>
          <td>${positionsHtml}</td>
          <td>${escapeHtml(item.status)}</td>
          <td>${escapeHtml(item.service)}</td>
          <td>${renderDeputies(item.deputies)}</td>
          <td>${periodText}<br><small>${escapeHtml(daysText)}</small></td>
          <td>${memo}</td>
          <td>${actionHtml}</td>
        `;

        tbody.appendChild(tr);
      });
    }

    function applyFilterAndRender() {
      const query = state.query.trim().toLowerCase();
      const rows = !query
        ? state.allRows.slice()
        : state.allRows.filter((item) => buildSearchText(item).includes(query));

      state.filteredRows = rows;
      renderRows(rows);
      updateCounters();
    }

    async function refreshActiveList(silent) {
      try {
        setButtonBusy(refreshButton, true, "Обновление...");
        if (!silent) {
          setStatus("active-message", "Загружаем актуальные данные...", "muted");
        }

        const rows = await loadActiveVacations();
        state.allRows = rows;
        state.byId = new Map(rows.map((row) => [Number(row.id), row]));

        applyFilterAndRender();

        if (lastSync) {
          lastSync.textContent = formatLocalDateTime(new Date());
        }

        if (!silent) {
          setStatus("active-message", `Список обновлен. Записей: ${rows.length}.`, "success");
        }
      } catch (error) {
        setStatus("active-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(refreshButton, false);
      }
    }

    function configureEditFormByRole() {
      if (!editForm) return;
      const specialCheckbox = editForm.is_special_employee;

      const readOnlyFields = [
        editForm.employee_full_name,
        editForm.service,
        editForm.employee_positions,
        editForm.start_date,
        editForm.end_date,
        editForm.memo,
      ].filter(Boolean);

      if (canFullEdit) {
        readOnlyFields.forEach((field) => {
          field.readOnly = false;
          field.disabled = false;
        });
        if (editForm.status) {
          editForm.status.disabled = false;
        }
        if (specialCheckbox) {
          specialCheckbox.disabled = false;
        }
        if (saveEditButton) {
          saveEditButton.textContent = "Сохранить изменения";
        }
        return;
      }

      readOnlyFields.forEach((field) => {
        field.readOnly = true;
        field.disabled = true;
      });
      if (editForm.status) {
        editForm.status.disabled = true;
      }
      if (specialCheckbox) {
        specialCheckbox.disabled = true;
      }
      if (saveEditButton) {
        saveEditButton.textContent = "Сохранить";
      }
    }

    function openEditModal(record) {
      if (!modal || !editForm || !editDeputiesList || !record) return;

      editForm.record_id.value = String(record.id);
      editForm.employee_full_name.value = record.employee_full_name || "";
      if (editForm.is_special_employee) {
        editForm.is_special_employee.checked = record.is_special_employee === true;
      }
      editForm.service.value = record.service || "";
      editForm.status.value = record.status || "В отпуске";
      editForm.employee_positions.value = positionsToMultiline(record.employee_positions);
      editForm.start_date.value = record.start_date || "";
      editForm.end_date.value = record.end_date || "";
      editForm.memo.value = record.memo || "";

      editDeputiesList.innerHTML = "";
      const deputies = asArray(record.deputies);
      if (deputies.length) {
        deputies.forEach((dep) => {
          const row = createDeputyRow("edit-deputy-row-template", dep);
          if (row) editDeputiesList.appendChild(row);
        });
      } else {
        const row = createDeputyRow("edit-deputy-row-template", {});
        if (row) editDeputiesList.appendChild(row);
      }

      configureEditFormByRole();
      setStatus(
        "edit-form-message",
        canFullEdit ? "Измените данные и сохраните запись." : "Изменение записи недоступно для вашей роли.",
        "muted"
      );
      modal.setAttribute("aria-hidden", "false");
      document.body.classList.add("modal-open");
      if (canFullEdit) {
        editForm.employee_full_name.focus();
      } else {
        addEditDeputyButton?.focus();
      }
    }

    function closeEditModal() {
      if (!modal) return;
      modal.setAttribute("aria-hidden", "true");
      document.body.classList.remove("modal-open");
    }

    async function handleArchive(recordId, button) {
      if (!canFullEdit) return;
      const ok = window.confirm("Перевести запись в статус 'Завершен'?");
      if (!ok) return;

      try {
        setButtonBusy(button, true, "Завершение...");
        await archiveVacation(recordId);
        await refreshActiveList(true);
        setStatus("active-message", "Запись переведена в статус 'Завершен'.", "success");
        showToast("Запись завершена.", "success");
      } catch (error) {
        setStatus("active-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(button, false);
      }
    }

    async function handleHardDelete(recordId, button) {
      if (!canDelete) return;
      const ok = window.confirm(
        "Удалить запись полностью из реестра? Это действие можно выполнить только администратору."
      );
      if (!ok) return;

      try {
        setButtonBusy(button, true, "Удаление...");
        await hardDeleteVacation(recordId);
        await refreshActiveList(true);
        setStatus("active-message", "Запись полностью удалена.", "success");
        showToast("Запись удалена.", "success");
      } catch (error) {
        setStatus("active-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(button, false);
      }
    }

    tbody.addEventListener("click", async (event) => {
      const button = event.target.closest("button[data-action]");
      if (!button) return;

      const action = button.dataset.action;
      const recordId = Number(button.dataset.id);
      if (!recordId) return;

      if (action === "archive") {
        await handleArchive(recordId, button);
      }

      if (action === "hard-delete") {
        await handleHardDelete(recordId, button);
      }

      if (action === "edit" && canEdit) {
        const record = state.byId.get(recordId);
        if (!record) {
          setStatus("active-message", "Не удалось найти запись для редактирования.", "error");
          return;
        }
        openEditModal(record);
      }
    });

    refreshButton?.addEventListener("click", () => refreshActiveList(false));

    searchInput?.addEventListener("input", () => {
      state.query = searchInput.value || "";
      applyFilterAndRender();
    });

    clearSearchButton?.addEventListener("click", () => {
      if (searchInput) searchInput.value = "";
      state.query = "";
      applyFilterAndRender();
    });

    if (canEdit && modal && editForm && editDeputiesList) {
      addEditDeputyButton?.addEventListener("click", () => {
        const row = createDeputyRow("edit-deputy-row-template", {});
        if (row) editDeputiesList.appendChild(row);
      });

      closeEditModalButton?.addEventListener("click", closeEditModal);
      cancelEditButton?.addEventListener("click", closeEditModal);

      modal.addEventListener("click", (event) => {
        const target = event.target;
        if (target && target instanceof HTMLElement && target.dataset.closeModal === "true") {
          closeEditModal();
        }
      });

      window.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && modal.getAttribute("aria-hidden") === "false") {
          closeEditModal();
        }
      });

      editForm.addEventListener("submit", async (event) => {
        event.preventDefault();

        try {
          setButtonBusy(saveEditButton, true, "Сохранение...");

          const recordId = Number(editForm.record_id.value);
          if (!recordId) {
            throw new Error("Не определен идентификатор записи для обновления.");
          }

          const payload = buildVacationPayload(editForm, editDeputiesList);
          await updateVacation(recordId, payload);

          setStatus("edit-form-message", "Изменения сохранены.", "success");
          showToast("Запись успешно обновлена.", "success");

          await refreshActiveList(true);
          closeEditModal();
          setStatus("active-message", "Данные сотрудника обновлены.", "success");
        } catch (error) {
          setStatus("edit-form-message", error.message, "error");
          showToast(error.message, "error");
        } finally {
          setButtonBusy(saveEditButton, false);
        }
      });
    }

    state.wsDisconnect = connectWebSocket(
      () => {
        setStatus("active-message", "Получено уведомление об изменении реестра. Обновляем таблицу...", "info");
        showToast("Реестр отпусков обновлен.", "info");
        refreshActiveList(true);
      },
      (isConnected) => {
        setWsState(isConnected);
      }
    );

    window.addEventListener("beforeunload", () => {
      state.wsDisconnect?.();
    });

    refreshActiveList(false);
    window.setInterval(() => refreshActiveList(true), AUTO_REFRESH_MS);
  }

  function initPlansPage() {
    const plansTbody = document.querySelector("#plans-table tbody");
    const logsTbody = document.querySelector("#sync-log-table tbody");
    const refreshButton = document.getElementById("plans-refresh-btn");
    const exportButton = document.getElementById("plans-export-btn");
    const applyTodayButton = document.getElementById("apply-plan-today-btn");
    const applyFilterButton = document.getElementById("plans-apply-filter-btn");
    const resetFilterButton = document.getElementById("plans-reset-filter-btn");

    const fioInput = document.getElementById("plans-filter-fio");
    const serviceInput = document.getElementById("plans-filter-service");
    const dateFromInput = document.getElementById("plans-filter-date-from");
    const dateToInput = document.getElementById("plans-filter-date-to");
    const includeFinishedInput = document.getElementById("plans-filter-include-finished");

    const totalCountEl = document.getElementById("plans-total-count");
    const activeCountEl = document.getElementById("plans-active-count");
    const futureCountEl = document.getElementById("plans-future-count");
    const lastSyncEl = document.getElementById("plans-last-sync");

    if (!plansTbody || !logsTbody) return;

    const state = {
      rows: [],
      logs: [],
      wsDisconnect: null,
    };

    function getFilters() {
      return {
        employeeFullName: fioInput?.value.trim() || "",
        service: serviceInput?.value.trim() || "",
        periodFrom: dateFromInput?.value || "",
        periodTo: dateToInput?.value || "",
        includeFinished: includeFinishedInput?.checked !== false,
      };
    }

    function updatePlanCounters(rows) {
      const todayIso = new Date().toISOString().slice(0, 10);
      const activeCount = rows.filter((row) => isActiveStatus(row.status) && row.start_date <= todayIso && row.end_date >= todayIso).length;
      const futureCount = rows.filter((row) => isActiveStatus(row.status) && row.start_date > todayIso).length;

      if (totalCountEl) totalCountEl.textContent = String(rows.length);
      if (activeCountEl) activeCountEl.textContent = String(activeCount);
      if (futureCountEl) futureCountEl.textContent = String(futureCount);
    }

    function renderPlanRows(rows) {
      plansTbody.innerHTML = "";

      if (!rows.length) {
        const tr = document.createElement("tr");
        tr.innerHTML = '<td colspan="9" class="empty-cell">По текущему фильтру записей нет.</td>';
        plansTbody.appendChild(tr);
        return;
      }

      rows.forEach((item) => {
        const tr = document.createElement("tr");
        if (item.is_special_employee) {
          tr.classList.add("row-special");
        }
        const positions = asArray(item.employee_positions).map(escapeHtml).join("<br>") || "—";
        const period = `${escapeHtml(formatDate(item.start_date))} — ${escapeHtml(formatDate(item.end_date))}`;
        const memo = item.memo ? escapeHtml(item.memo) : "—";

        tr.innerHTML = `
          <td>${item.id}</td>
          <td>${renderEmployeeCell(item)}</td>
          <td>${positions}</td>
          <td>${escapeHtml(item.service || "—")}</td>
          <td>${escapeHtml(item.status || "—")}</td>
          <td>${period}</td>
          <td>${renderDeputies(item.deputies)}</td>
          <td>${memo}</td>
          <td>
            <button type="button" class="button compact danger outline" data-action="hard-delete-plan" data-id="${item.id}">
              Удалить
            </button>
          </td>
        `;
        plansTbody.appendChild(tr);
      });
    }

    function formatActionType(value) {
      if (value === "excel_import") return "Импорт Excel";
      if (value === "manual_sync") return "Ручная синхронизация";
      if (value === "manual_archive") return "Ручное завершение";
      if (value === "manual_hard_delete") return "Ручное удаление";
      if (value === "scheduled_sync") return "Автосинхронизация";
      if (value === "scheduled_return_sync") return "Проверка выхода из отпуска";
      return value || "—";
    }

    async function handlePlanHardDelete(recordId, button) {
      const row = button?.closest("tr");
      const employeeName = row?.querySelector("td:nth-child(2)")?.textContent?.trim() || `ID ${recordId}`;
      const ok = window.confirm(`Полностью удалить запись из плана отпусков?\n${employeeName}`);
      if (!ok) return;

      try {
        setButtonBusy(button, true, "Удаление...");
        await hardDeleteVacation(recordId);
        setStatus("plans-message", `Запись удалена (ID ${recordId}).`, "success");
        showToast("Запись плана удалена.", "success");
        await refreshAll(true);
      } catch (error) {
        setStatus("plans-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(button, false);
      }
    }

    function formatLogSummary(log) {
      const payload = log?.payload || {};
      if (log?.action_type === "excel_import") {
        return [
          `Создано: ${payload.created_count ?? 0}`,
          `Обновлено: ${payload.updated_count ?? 0}`,
          `Закрыто: ${payload.reconciled_archived_count ?? 0}`,
          `Удалено будущих: ${payload.reconciled_deleted_count ?? 0}`,
          `Ошибок: ${payload.error_count ?? 0}`,
        ].join("; ");
      }

      const baseSummary = [
        `Активировано: ${payload.activated_count ?? 0}`,
        `Завершено: ${payload.finalized_count ?? 0}`,
        `Удалено старых: ${payload.deleted_count ?? 0}`,
      ].join("; ");

      const details = Array.isArray(payload.messages) ? payload.messages.filter(Boolean) : [];
      if (!details.length) return baseSummary;

      const preview = details.slice(0, 3).join(" | ");
      const suffix = details.length > 3 ? ` | и еще ${details.length - 3}` : "";
      return `${baseSummary}; ${preview}${suffix}`;
    }

    function renderLogs(logs) {
      logsTbody.innerHTML = "";

      if (!logs.length) {
        const tr = document.createElement("tr");
        tr.innerHTML = '<td colspan="5" class="empty-cell">Журнал пока пуст.</td>';
        logsTbody.appendChild(tr);
        return;
      }

      logs.forEach((item) => {
        const tr = document.createElement("tr");
        const createdAt = item.created_at ? formatLocalDateTime(new Date(item.created_at)) : "—";
        tr.innerHTML = `
          <td>${escapeHtml(createdAt)}</td>
          <td>${escapeHtml(formatActionType(item.action_type))}</td>
          <td>${escapeHtml(item.source_name || "—")}</td>
          <td>${escapeHtml(item.actor_username || "system")}</td>
          <td>${escapeHtml(formatLogSummary(item))}</td>
        `;
        logsTbody.appendChild(tr);
      });
    }

    async function refreshPlans(silent) {
      try {
        setButtonBusy(refreshButton, true, "Обновление...");
        if (!silent) setStatus("plans-message", "Загружаем план отпусков...", "muted");

        const rows = await loadPlannedVacations(getFilters());
        state.rows = rows;
        renderPlanRows(rows);
        updatePlanCounters(rows);
        if (lastSyncEl) lastSyncEl.textContent = formatLocalDateTime(new Date());

        if (!silent) setStatus("plans-message", `План обновлен. Записей: ${rows.length}.`, "success");
      } catch (error) {
        setStatus("plans-message", error.message, "error");
      } finally {
        setButtonBusy(refreshButton, false);
      }
    }

    async function refreshLogs(silent) {
      try {
        const logs = await loadSyncLogs(100);
        state.logs = logs;
        renderLogs(logs);
        if (!silent) {
          setStatus("sync-log-message", `Загружено записей журнала: ${logs.length}.`, "muted");
        }
      } catch (error) {
        setStatus("sync-log-message", error.message, "error");
      }
    }

    async function refreshAll(silent) {
      await Promise.all([refreshPlans(silent), refreshLogs(silent)]);
    }

    refreshButton?.addEventListener("click", () => refreshAll(false));
    exportButton?.addEventListener("click", () => {
      const url = buildPlansExportUrl(getFilters());
      window.location.href = url;
    });
    applyFilterButton?.addEventListener("click", () => refreshPlans(false));
    resetFilterButton?.addEventListener("click", () => {
      if (fioInput) fioInput.value = "";
      if (serviceInput) serviceInput.value = "";
      if (dateFromInput) dateFromInput.value = "";
      if (dateToInput) dateToInput.value = "";
      if (includeFinishedInput) includeFinishedInput.checked = true;
      refreshPlans(false);
    });

    applyTodayButton?.addEventListener("click", async () => {
      try {
        setButtonBusy(applyTodayButton, true, "Применение...");
        const result = await applyPlanTodayNow();
        setStatus(
          "plans-message",
          `Синхронизация выполнена. Активировано: ${result.activated_count}, завершено: ${result.finalized_count}, удалено старых: ${result.deleted_count}.`,
          "success"
        );
        showToast("План на сегодня применен.", "success");
        await refreshAll(true);
      } catch (error) {
        setStatus("plans-message", error.message, "error");
        showToast(error.message, "error");
      } finally {
        setButtonBusy(applyTodayButton, false);
      }
    });

    plansTbody.addEventListener("click", async (event) => {
      const button = event.target.closest("button[data-action='hard-delete-plan']");
      if (!button) return;
      const recordId = Number(button.dataset.id || 0);
      if (!recordId) return;
      await handlePlanHardDelete(recordId, button);
    });

    state.wsDisconnect = connectWebSocket(
      () => {
        setStatus("plans-message", "Получено уведомление об обновлении. Обновляем план...", "info");
        refreshAll(true);
      },
      () => {
        /* no-op */
      }
    );

    window.addEventListener("beforeunload", () => {
      state.wsDisconnect?.();
    });

    refreshAll(false);
    window.setInterval(() => refreshAll(true), AUTO_REFRESH_MS);
  }

  function initPublicPage() {
    const tableBody = document.querySelector("#public-table tbody");
    const tabCurrentButton = document.getElementById("public-tab-current");
    const tabFinishedButton = document.getElementById("public-tab-finished");
    const refreshButton = document.getElementById("public-refresh");
    const exportLink = document.getElementById("public-export-link");
    const searchInput = document.getElementById("public-search");
    const resetSearchButton = document.getElementById("public-search-reset");
    const wsState = document.getElementById("public-ws-state");
    const lastSync = document.getElementById("public-last-sync");
    const visibleCount = document.getElementById("public-visible-count");

    if (!tableBody) return;

    const state = {
      tab: "current",
      allRows: [],
      filteredRows: [],
      query: "",
      wsDisconnect: null,
    };

    function setWsState(isConnected) {
      if (!wsState) return;
      wsState.textContent = isConnected ? "Онлайн" : "Нет связи";
      wsState.style.color = isConnected ? "#136640" : "#8b1f17";
    }

    function setTabUI() {
      if (tabCurrentButton) {
        tabCurrentButton.classList.toggle("secondary", state.tab === "current");
        tabCurrentButton.classList.toggle("ghost", state.tab !== "current");
      }
      if (tabFinishedButton) {
        tabFinishedButton.classList.toggle("secondary", state.tab === "finished");
        tabFinishedButton.classList.toggle("ghost", state.tab !== "finished");
      }
      if (exportLink) {
        exportLink.href = buildPublicExportUrl(state.tab);
      }
    }

    function updateCounters() {
      if (visibleCount) visibleCount.textContent = String(state.filteredRows.length);
    }

    function renderRows(rows) {
      tableBody.innerHTML = "";

      if (!rows.length) {
        const tr = document.createElement("tr");
        tr.innerHTML = '<td colspan="7" class="empty-cell">По текущему фильтру записей нет.</td>';
        tableBody.appendChild(tr);
        return;
      }

      rows.forEach((item) => {
        const tr = document.createElement("tr");
        if (item.is_special_employee) {
          tr.classList.add("row-special");
        }
        const positionsHtml = asArray(item.employee_positions).map(escapeHtml).join("<br>") || "—";
        const memo = item.memo ? escapeHtml(item.memo) : "—";
        const periodText = `${escapeHtml(formatDate(item.start_date))} — ${escapeHtml(formatDate(item.end_date))}`;

        tr.innerHTML = `
          <td>${renderEmployeeCell(item)}</td>
          <td>${positionsHtml}</td>
          <td>${escapeHtml(item.status)}</td>
          <td>${escapeHtml(item.service || "—")}</td>
          <td>${renderDeputies(item.deputies)}</td>
          <td>${periodText}</td>
          <td>${memo}</td>
        `;
        tableBody.appendChild(tr);
      });
    }

    function applyFilterAndRender() {
      const query = state.query.trim().toLowerCase();
      const rows = !query
        ? state.allRows.slice()
        : state.allRows.filter((item) => buildSearchText(item).includes(query));

      state.filteredRows = rows;
      renderRows(rows);
      updateCounters();
    }

    async function refreshPublicTable(silent) {
      try {
        setButtonBusy(refreshButton, true, "Обновление...");
        if (!silent) setStatus("public-message", "Загружаем данные...", "muted");

        const rows = await loadPublicVacations(state.tab);
        state.allRows = rows;
        applyFilterAndRender();

        if (lastSync) lastSync.textContent = formatLocalDateTime(new Date());
        if (!silent) {
          const tabLabel = state.tab === "current" ? "Текущие" : "Завершенные";
          setStatus("public-message", `${tabLabel}: загружено ${rows.length} записей.`, "success");
        }
      } catch (error) {
        setStatus("public-message", error.message, "error");
      } finally {
        setButtonBusy(refreshButton, false);
      }
    }

    tabCurrentButton?.addEventListener("click", () => {
      if (state.tab === "current") return;
      state.tab = "current";
      setTabUI();
      refreshPublicTable(false);
    });

    tabFinishedButton?.addEventListener("click", () => {
      if (state.tab === "finished") return;
      state.tab = "finished";
      setTabUI();
      refreshPublicTable(false);
    });

    refreshButton?.addEventListener("click", () => refreshPublicTable(false));

    searchInput?.addEventListener("input", () => {
      state.query = searchInput.value || "";
      applyFilterAndRender();
    });

    resetSearchButton?.addEventListener("click", () => {
      if (searchInput) searchInput.value = "";
      state.query = "";
      applyFilterAndRender();
    });

    state.wsDisconnect = connectWebSocket(
      () => {
        setStatus("public-message", "Получено уведомление об обновлении. Обновляем таблицу...", "info");
        refreshPublicTable(true);
      },
      (isConnected) => {
        setWsState(isConnected);
      }
    );

    window.addEventListener("beforeunload", () => {
      state.wsDisconnect?.();
    });

    setTabUI();
    refreshPublicTable(false);
    window.setInterval(() => refreshPublicTable(true), AUTO_REFRESH_MS);
  }

  function initAdminPage() {
    const tableBody = document.querySelector("#admin-clients-table tbody");
    const refreshButton = document.getElementById("admin-clients-refresh-btn");
    const totalCounter = document.getElementById("admin-clients-total");
    const installedCounter = document.getElementById("admin-clients-installed");
    const onlineCounter = document.getElementById("admin-clients-online");
    const outdatedCounter = document.getElementById("admin-clients-outdated");
    if (!tableBody) return;

    function formatLastSeen(value) {
      if (!value) return "—";
      try {
        return formatLocalDateTime(new Date(value));
      } catch {
        return String(value);
      }
    }

    function renderClientRows(rows) {
      tableBody.innerHTML = "";
      const installedCount = rows.filter((row) => row.client_id || row.mac_address || row.hostname).length;
      const onlineCount = rows.filter((row) => row.is_online).length;
      const outdatedCount = rows.filter((row) => row.is_outdated).length;
      if (totalCounter) totalCounter.textContent = String(rows.length);
      if (installedCounter) installedCounter.textContent = String(installedCount);
      if (onlineCounter) onlineCounter.textContent = String(onlineCount);
      if (outdatedCounter) outdatedCounter.textContent = String(outdatedCount);

      if (!rows.length) {
        const tr = document.createElement("tr");
        tr.innerHTML = '<td colspan="10" class="empty-cell">Клиенты еще не отправляли heartbeat.</td>';
        tableBody.appendChild(tr);
        return;
      }

      rows.forEach((row) => {
        const tr = document.createElement("tr");
        const onlineChip = row.is_online
          ? '<span class="chip chip-client">Онлайн</span>'
          : '<span class="chip chip-editor">Офлайн</span>';
        const versionChip = row.is_outdated
          ? '<span class="chip chip-editor">Устарела</span>'
          : '<span class="chip chip-client">Актуальна</span>';
        const updateError = row.update_error ? `<br><small>${escapeHtml(row.update_error)}</small>` : "";

        tr.innerHTML = `
          <td>${escapeHtml(row.client_id || "—")}</td>
          <td>${escapeHtml(row.mac_address || "—")}</td>
          <td>${escapeHtml(row.hostname || "—")}</td>
          <td>${escapeHtml(row.username || "—")}</td>
          <td>${escapeHtml(`${row.os_name || "—"} ${row.os_version || ""}`.trim())}</td>
          <td>${escapeHtml(row.app_version || "unknown")}<br>${versionChip}</td>
          <td>${onlineChip}</td>
          <td>${escapeHtml(row.update_status || "—")}${updateError}</td>
          <td>${escapeHtml(formatLastSeen(row.last_seen_at))}</td>
          <td>${escapeHtml(row.ip_address || "—")}</td>
        `;
        tableBody.appendChild(tr);
      });
    }

    async function refreshClientMonitor(silent) {
      try {
        setButtonBusy(refreshButton, true, "Обновление...");
        if (!silent) {
          setStatus("admin-clients-message", "Загружаем монитор клиентов...", "muted");
        }
        const rows = await loadAdminClientHeartbeats();
        renderClientRows(rows);
        if (!silent) {
          setStatus("admin-clients-message", `Клиентов в мониторе: ${rows.length}.`, "success");
        }
      } catch (error) {
        setStatus("admin-clients-message", error.message, "error");
      } finally {
        setButtonBusy(refreshButton, false);
      }
    }

    refreshButton?.addEventListener("click", () => refreshClientMonitor(false));
    refreshClientMonitor(true);
    window.setInterval(() => refreshClientMonitor(true), AUTO_REFRESH_MS);
  }

  if (page === "index") {
    initIndexPage();
  }

  if (page === "active") {
    initActivePage();
  }

  if (page === "plans") {
    initPlansPage();
  }

  if (page === "public") {
    initPublicPage();
  }

  if (page === "admin") {
    initAdminPage();
  }
})();
