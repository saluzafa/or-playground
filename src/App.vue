<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import CodeEditor from './components/CodeEditor.vue'

type ReasoningEffort = 'low' | 'medium' | 'high'

interface RequestSettings {
  apiKey: string
  temperature: number
  topP: number
  reasoningEnabled: boolean
  reasoningEffort: ReasoningEffort
}

interface PromptPreset {
  id: string
  name: string
  model: string
  systemMessage: string
  userMessage: string
  settings: RequestSettings
  updatedAt: string
  filename: string
}

interface OpenRouterModel {
  id: string
  name: string
}

interface OpenRouterUsage {
  promptTokens: number | null
  completionTokens: number | null
  totalTokens: number | null
  cost: number | string | null
  cachedTokens: number | null
  requestDurationSeconds: number | null
}

const DB_NAME = 'or-playground-db'
const DB_VERSION = 2
const STORE_NAME = 'app-kv'
const DIRECTORY_HANDLE_KEY = 'preset-directory-handle'
const PRESET_QUERY_KEY = 'preset'
const DEFAULT_SETTINGS: RequestSettings = {
  apiKey: '',
  temperature: 0.7,
  topP: 1,
  reasoningEnabled: true,
  reasoningEffort: 'medium',
}

const model = ref('openai/gpt-4.1-mini')
const systemMessage = ref('You are a helpful assistant.')
const userMessage = ref('')
const responseText = ref('')
const responseJson = ref('')
const responseUsage = ref<OpenRouterUsage | null>(null)
const errorMessage = ref('')
const isSending = ref(false)
const isModelInputFocused = ref(false)
const isLoadingModels = ref(false)
const modelLoadError = ref('')
const openRouterModels = ref<OpenRouterModel[]>([])
let presetAutoSyncTimer: ReturnType<typeof setInterval> | null = null
let presetAutoSaveTimer: ReturnType<typeof setTimeout> | null = null
const suppressPresetAutoSave = ref(false)

const presetName = ref('')
const selectedPresetId = ref('')
const presets = ref<PromptPreset[]>([])
const syncingPresets = ref(false)
const directoryLabel = ref('No directory connected')

const settings = reactive<RequestSettings>({
  ...DEFAULT_SETTINGS,
})

const presetDirectoryHandle = ref<FileSystemDirectoryHandle | null>(null)

const canUseDirectoryApi = computed(() => typeof window !== 'undefined' && 'showDirectoryPicker' in window)
const hasConnectedDirectory = computed(() => !!presetDirectoryHandle.value)

const selectedPreset = computed(() => presets.value.find((preset) => preset.id === selectedPresetId.value) ?? null)
const canRenameSelectedPreset = computed(() => {
  if (!presetDirectoryHandle.value || !selectedPreset.value) {
    return false
  }

  const nextName = presetName.value.trim()
  return !!nextName && nextName !== selectedPreset.value.name
})
const filteredModelSuggestions = computed(() => {
  const query = model.value.trim().toLowerCase()
  const source = openRouterModels.value

  if (!query) {
    return source.slice(0, 12)
  }

  return source.filter((entry) => entry.id.toLowerCase().includes(query) || entry.name.toLowerCase().includes(query)).slice(0, 12)
})
const showModelSuggestions = computed(() => isModelInputFocused.value && filteredModelSuggestions.value.length > 0)

const canSend = computed(() => !!settings.apiKey.trim() && !!model.value.trim() && !!userMessage.value.trim())

async function openDbWithVersion(version?: number) {
  return await new Promise<IDBDatabase>((resolve, reject) => {
    const request = typeof version === 'number' ? indexedDB.open(DB_NAME, version) : indexedDB.open(DB_NAME)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME)
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function openDb() {
  let db = await openDbWithVersion(DB_VERSION)
  if (db.objectStoreNames.contains(STORE_NAME)) {
    return db
  }

  const nextVersion = Math.max(db.version + 1, DB_VERSION + 1)
  db.close()
  db = await openDbWithVersion(nextVersion)
  return db
}

async function idbSet(key: string, value: unknown) {
  const db = await openDb()
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite')
    tx.objectStore(STORE_NAME).put(value, key)
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
  db.close()
}

async function idbGet<T>(key: string): Promise<T | null> {
  const db = await openDb()
  const result = await new Promise<T | null>((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readonly')
    const request = tx.objectStore(STORE_NAME).get(key)
    request.onsuccess = () => resolve((request.result as T | undefined) ?? null)
    request.onerror = () => reject(request.error)
  })
  db.close()
  return result
}

async function idbDelete(key: string) {
  const db = await openDb()
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite')
    tx.objectStore(STORE_NAME).delete(key)
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error)
  })
  db.close()
}

function safeParse<T>(value: string | null, fallback: T): T {
  if (!value) {
    return fallback
  }
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}

function toReasoningEffort(value: unknown, fallback: ReasoningEffort = DEFAULT_SETTINGS.reasoningEffort): ReasoningEffort {
  if (value === 'low' || value === 'medium' || value === 'high') {
    return value
  }
  return fallback
}

function toRequestSettings(value: unknown): RequestSettings {
  const source = value && typeof value === 'object' ? (value as Record<string, unknown>) : {}
  return {
    apiKey: typeof source.apiKey === 'string' ? source.apiKey : DEFAULT_SETTINGS.apiKey,
    temperature: typeof source.temperature === 'number' ? source.temperature : DEFAULT_SETTINGS.temperature,
    topP: typeof source.topP === 'number' ? source.topP : DEFAULT_SETTINGS.topP,
    reasoningEnabled:
      typeof source.reasoningEnabled === 'boolean' ? source.reasoningEnabled : DEFAULT_SETTINGS.reasoningEnabled,
    reasoningEffort: toReasoningEffort(source.reasoningEffort),
  }
}

function snapshotSettings(): RequestSettings {
  return {
    apiKey: settings.apiKey,
    temperature: settings.temperature,
    topP: settings.topP,
    reasoningEnabled: settings.reasoningEnabled,
    reasoningEffort: settings.reasoningEffort,
  }
}

function applySettings(nextSettings: RequestSettings) {
  settings.apiKey = nextSettings.apiKey
  settings.temperature = nextSettings.temperature
  settings.topP = nextSettings.topP
  settings.reasoningEnabled = nextSettings.reasoningEnabled
  settings.reasoningEffort = nextSettings.reasoningEffort
}

function cleanFilename(value: string) {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'preset'
}

function toTextContent(content: unknown): string {
  if (typeof content === 'string') {
    return content
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === 'string') {
          return part
        }
        if (part && typeof part === 'object' && 'text' in part && typeof part.text === 'string') {
          return part.text
        }
        return ''
      })
      .filter(Boolean)
      .join('\n')
  }
  return ''
}

function getPresetIdFromUrl() {
  if (typeof window === 'undefined') {
    return ''
  }

  return new URLSearchParams(window.location.search).get(PRESET_QUERY_KEY)?.trim() ?? ''
}

function setPresetIdInUrl(presetId: string) {
  if (typeof window === 'undefined') {
    return
  }

  const url = new URL(window.location.href)
  if (presetId) {
    url.searchParams.set(PRESET_QUERY_KEY, presetId)
  } else {
    url.searchParams.delete(PRESET_QUERY_KEY)
  }

  const nextPath = `${url.pathname}${url.search}${url.hash}`
  window.history.replaceState(window.history.state, '', nextPath)
}

async function ensureDirectoryPermission(handle: FileSystemDirectoryHandle) {
  const descriptor = { mode: 'readwrite' as const }
  const permissionHandle = handle as FileSystemDirectoryHandle & {
    queryPermission?: (desc: { mode: 'readwrite' | 'read' }) => Promise<'granted' | 'prompt' | 'denied'>
    requestPermission?: (desc: { mode: 'readwrite' | 'read' }) => Promise<'granted' | 'prompt' | 'denied'>
  }

  if (typeof permissionHandle.queryPermission !== 'function' || typeof permissionHandle.requestPermission !== 'function') {
    return true
  }

  if ((await permissionHandle.queryPermission(descriptor)) === 'granted') {
    return true
  }
  return (await permissionHandle.requestPermission(descriptor)) === 'granted'
}

async function syncPresetsFromDirectory() {
  if (!presetDirectoryHandle.value) {
    return
  }

  syncingPresets.value = true
  errorMessage.value = ''

  try {
    const nextPresets: PromptPreset[] = []
    const hadSelectedPresetBefore = !!selectedPreset.value

    const directoryEntries = (
      presetDirectoryHandle.value as FileSystemDirectoryHandle & {
        entries?: () => AsyncIterableIterator<[string, FileSystemHandle]>
      }
    ).entries?.()

    if (!directoryEntries) {
      throw new Error('Directory iteration is not supported in this browser.')
    }

    for await (const [filename, handle] of directoryEntries) {
      if (handle.kind !== 'file' || !filename.endsWith('.json')) {
        continue
      }

      const fileHandle = handle as FileSystemFileHandle
      const file = await fileHandle.getFile()
      const raw = await file.text()
      const parsed = safeParse<Record<string, unknown>>(raw, {})

      if (typeof parsed.name !== 'string') {
        continue
      }

      nextPresets.push({
        id: typeof parsed.id === 'string' ? parsed.id : filename.replace(/\.json$/, ''),
        name: parsed.name,
        model: typeof parsed.model === 'string' ? parsed.model : '',
        systemMessage: typeof parsed.systemMessage === 'string' ? parsed.systemMessage : '',
        userMessage: typeof parsed.userMessage === 'string' ? parsed.userMessage : '',
        settings: toRequestSettings(
          parsed.settings && typeof parsed.settings === 'object'
            ? parsed.settings
            : {
                apiKey: parsed.apiKey,
                temperature: parsed.temperature,
                topP: parsed.topP,
                reasoningEnabled: parsed.reasoningEnabled,
                reasoningEffort: parsed.reasoningEffort,
              },
        ),
        updatedAt: typeof parsed.updatedAt === 'string' ? parsed.updatedAt : new Date().toISOString(),
        filename,
      })
    }

    nextPresets.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    presets.value = nextPresets

    if (selectedPresetId.value && !nextPresets.some((preset) => preset.id === selectedPresetId.value)) {
      selectedPresetId.value = ''
    } else if (selectedPresetId.value && !hadSelectedPresetBefore) {
      await loadSelectedPreset()
    }
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to load presets from directory.'
  } finally {
    syncingPresets.value = false
  }
}

function setAutoSync(enabled: boolean) {
  if (!enabled) {
    if (presetAutoSyncTimer) {
      clearInterval(presetAutoSyncTimer)
      presetAutoSyncTimer = null
    }
    return
  }

  if (!presetAutoSyncTimer) {
    presetAutoSyncTimer = setInterval(() => {
      void syncPresetsFromDirectory()
    }, 15000)
  }
}

async function reconnectSavedPresetDirectory() {
  if (!canUseDirectoryApi.value) {
    return
  }

  try {
    const handle = await idbGet<FileSystemDirectoryHandle>(DIRECTORY_HANDLE_KEY)
    if (!handle) {
      return
    }

    const granted = await ensureDirectoryPermission(handle)
    if (!granted) {
      return
    }

    presetDirectoryHandle.value = handle
    directoryLabel.value = handle.name
    await syncPresetsFromDirectory()
  } catch {
    // Ignore persisted-handle restore errors.
  }
}

async function connectPresetDirectory() {
  if (!canUseDirectoryApi.value) {
    errorMessage.value = 'File System Access API is not available in this browser.'
    return
  }

  errorMessage.value = ''

  try {
    const picker = (
      window as unknown as Window & { showDirectoryPicker: () => Promise<FileSystemDirectoryHandle> }
    ).showDirectoryPicker
    const handle = await picker()
    const granted = await ensureDirectoryPermission(handle)

    if (!granted) {
      errorMessage.value = 'Read/write permission was not granted for the selected directory.'
      return
    }

    presetDirectoryHandle.value = handle
    directoryLabel.value = handle.name
    await idbSet(DIRECTORY_HANDLE_KEY, handle)
    await syncPresetsFromDirectory()
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      return
    }
    errorMessage.value = error instanceof Error ? error.message : 'Unable to connect directory.'
  }
}

async function disconnectPresetDirectory() {
  presetDirectoryHandle.value = null
  directoryLabel.value = 'No directory connected'
  selectedPresetId.value = ''
  presets.value = []
  errorMessage.value = ''
  await idbDelete(DIRECTORY_HANDLE_KEY)
}

async function writePreset(preset: PromptPreset) {
  if (!presetDirectoryHandle.value) {
    throw new Error('Connect a preset directory first.')
  }

  const fileHandle = await presetDirectoryHandle.value.getFileHandle(preset.filename, { create: true })
  const writable = await fileHandle.createWritable()
  await writable.write(
    JSON.stringify(
      {
        id: preset.id,
        name: preset.name,
        model: preset.model,
        systemMessage: preset.systemMessage,
        userMessage: preset.userMessage,
        settings: preset.settings,
        updatedAt: preset.updatedAt,
      },
      null,
      2,
    ),
  )
  await writable.close()
}

async function savePreset() {
  if (!presetDirectoryHandle.value) {
    errorMessage.value = 'Connect a preset directory first.'
    return
  }

  const name = presetName.value.trim() || selectedPreset.value?.name || 'Untitled preset'
  const now = new Date().toISOString()
  const id = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}`
  const filename = `${id}-${cleanFilename(name)}.json`

  const preset: PromptPreset = {
    id,
    filename,
    name,
    model: model.value,
    systemMessage: systemMessage.value,
    userMessage: userMessage.value,
    settings: snapshotSettings(),
    updatedAt: now,
  }

  try {
    await writePreset(preset)
    presetName.value = ''
    selectedPresetId.value = preset.id
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to save preset.'
  }
}

async function loadSelectedPreset() {
  if (!selectedPreset.value) {
    return
  }

  suppressPresetAutoSave.value = true
  model.value = selectedPreset.value.model
  systemMessage.value = selectedPreset.value.systemMessage
  userMessage.value = selectedPreset.value.userMessage
  applySettings(selectedPreset.value.settings)
  presetName.value = selectedPreset.value.name
  await nextTick()
  suppressPresetAutoSave.value = false
}

async function deleteSelectedPreset() {
  if (!presetDirectoryHandle.value || !selectedPreset.value) {
    return
  }

  try {
    await presetDirectoryHandle.value.removeEntry(selectedPreset.value.filename)
    selectedPresetId.value = ''
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to delete preset.'
  }
}

async function renameSelectedPreset() {
  if (!presetDirectoryHandle.value || !selectedPreset.value) {
    return
  }

  const nextName = presetName.value.trim()
  if (!nextName || nextName === selectedPreset.value.name) {
    return
  }

  const updatedPreset: PromptPreset = {
    ...selectedPreset.value,
    name: nextName,
    updatedAt: new Date().toISOString(),
  }

  try {
    await writePreset(updatedPreset)
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to rename preset.'
  }
}

function toNumberOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function toCostOrNull(value: unknown): number | string | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value
  }
  if (typeof value === 'string' && value.trim()) {
    return value
  }
  return null
}

function extractUsage(payload: unknown, requestDurationSeconds: number | null): OpenRouterUsage {
  const usage = payload && typeof payload === 'object' ? (payload as { usage?: unknown }).usage : null
  if (!usage || typeof usage !== 'object') {
    return {
      promptTokens: null,
      completionTokens: null,
      totalTokens: null,
      cost: null,
      cachedTokens: null,
      requestDurationSeconds,
    }
  }

  const usageRecord = usage as Record<string, unknown>
  const promptTokenDetails =
    usageRecord.prompt_tokens_details && typeof usageRecord.prompt_tokens_details === 'object'
      ? (usageRecord.prompt_tokens_details as Record<string, unknown>)
      : null

  return {
    promptTokens: toNumberOrNull(usageRecord.prompt_tokens),
    completionTokens: toNumberOrNull(usageRecord.completion_tokens),
    totalTokens: toNumberOrNull(usageRecord.total_tokens),
    cost: toCostOrNull(usageRecord.cost),
    cachedTokens: toNumberOrNull(promptTokenDetails?.cached_tokens),
    requestDurationSeconds,
  }
}

function formatUsageNumber(value: number | null): string {
  if (value === null) {
    return 'N/A'
  }
  return value.toLocaleString()
}

function formatUsageCost(value: number | string | null): string {
  if (value === null) {
    return 'N/A'
  }
  if (typeof value === 'number') {
    return value.toLocaleString(undefined, {
      minimumFractionDigits: 0,
      maximumFractionDigits: 6,
    })
  }
  return value
}

function formatUsageDuration(value: number | null): string {
  if (value === null) {
    return 'N/A'
  }
  return value.toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
}

async function sendPrompt() {
  if (!canSend.value) {
    return
  }

  isSending.value = true
  errorMessage.value = ''
  responseUsage.value = null

  try {
    const messages: Array<{ role: 'system' | 'user'; content: string }> = []
    if (systemMessage.value.trim()) {
      messages.push({ role: 'system', content: systemMessage.value.trim() })
    }
    messages.push({ role: 'user', content: userMessage.value.trim() })

    const requestStartedAt = performance.now()
    const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${settings.apiKey.trim()}`,
      },
      body: JSON.stringify({
        model: model.value.trim(),
        messages,
        temperature: settings.temperature,
        top_p: settings.topP,
        ...(settings.reasoningEnabled
          ? {
              reasoning: {
                effort: settings.reasoningEffort,
              },
            }
          : {}),
      }),
    })
    const requestDurationSeconds = (performance.now() - requestStartedAt) / 1000

    const payload = await response.json()

    if (!response.ok) {
      const apiError =
        typeof payload?.error?.message === 'string'
          ? payload.error.message
          : `OpenRouter request failed with status ${response.status}`
      throw new Error(apiError)
    }

    const content = payload?.choices?.[0]?.message?.content
    responseText.value = toTextContent(content) || '[No text content in model response]'
    responseJson.value = JSON.stringify(payload, null, 2)
    responseUsage.value = extractUsage(payload, requestDurationSeconds)
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Request failed.'
  } finally {
    isSending.value = false
  }
}

function sendPromptOnShortcut(event: KeyboardEvent) {
  if (event.key !== 'Enter') {
    return
  }
  if (!(event.metaKey || event.ctrlKey)) {
    return
  }

  event.preventDefault()
  event.stopPropagation()
  event.stopImmediatePropagation()

  void sendPrompt()
}

function swallowSaveShortcut(event: KeyboardEvent) {
  if (event.key.toLowerCase() !== 's') {
    return false
  }
  if (!(event.metaKey || event.ctrlKey)) {
    return false
  }

  event.preventDefault()
  event.stopPropagation()
  event.stopImmediatePropagation()
  return true
}

function handleWindowKeydown(event: KeyboardEvent) {
  if (swallowSaveShortcut(event)) {
    return
  }
  sendPromptOnShortcut(event)
}

async function loadOpenRouterModels() {
  isLoadingModels.value = true
  modelLoadError.value = ''

  try {
    const response = await fetch('https://openrouter.ai/api/v1/models')
    const payload = await response.json()

    if (!response.ok) {
      throw new Error(`Unable to load model suggestions (${response.status})`)
    }

    const data: unknown[] = Array.isArray(payload?.data) ? payload.data : []
    openRouterModels.value = data
      .filter((entry: unknown): entry is Record<string, unknown> => !!entry && typeof entry === 'object')
      .map((entry: Record<string, unknown>) => ({
        id: typeof entry.id === 'string' ? entry.id : '',
        name: typeof entry.name === 'string' ? entry.name : '',
      }))
      .filter((entry: OpenRouterModel) => !!entry.id)
      .sort((a: OpenRouterModel, b: OpenRouterModel) => a.id.localeCompare(b.id))
  } catch (error) {
    modelLoadError.value = error instanceof Error ? error.message : 'Unable to load model suggestions.'
  } finally {
    isLoadingModels.value = false
  }
}

function applyModelSuggestion(value: string) {
  model.value = value
  isModelInputFocused.value = false
}

function clearPresetAutoSaveTimer() {
  if (presetAutoSaveTimer) {
    clearTimeout(presetAutoSaveTimer)
    presetAutoSaveTimer = null
  }
}

function hasSelectedPresetChanges() {
  if (!selectedPreset.value) {
    return false
  }

  return (
    model.value !== selectedPreset.value.model ||
    systemMessage.value !== selectedPreset.value.systemMessage ||
    userMessage.value !== selectedPreset.value.userMessage ||
    settings.apiKey !== selectedPreset.value.settings.apiKey ||
    settings.temperature !== selectedPreset.value.settings.temperature ||
    settings.topP !== selectedPreset.value.settings.topP ||
    settings.reasoningEnabled !== selectedPreset.value.settings.reasoningEnabled ||
    settings.reasoningEffort !== selectedPreset.value.settings.reasoningEffort
  )
}

async function autoSaveSelectedPreset() {
  if (!presetDirectoryHandle.value || !selectedPreset.value || suppressPresetAutoSave.value) {
    return
  }

  if (!hasSelectedPresetChanges()) {
    return
  }

  const updatedPreset: PromptPreset = {
    ...selectedPreset.value,
    name: selectedPreset.value.name,
    model: model.value,
    systemMessage: systemMessage.value,
    userMessage: userMessage.value,
    settings: snapshotSettings(),
    updatedAt: new Date().toISOString(),
  }

  try {
    await writePreset(updatedPreset)
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to auto-save preset.'
  }
}

function queueSelectedPresetAutoSave() {
  if (!presetDirectoryHandle.value || !selectedPreset.value || suppressPresetAutoSave.value) {
    return
  }

  clearPresetAutoSaveTimer()
  presetAutoSaveTimer = setTimeout(() => {
    void autoSaveSelectedPreset()
  }, 500)
}

watch(
  presetDirectoryHandle,
  (handle) => {
    setAutoSync(!!handle)
  },
  { immediate: true },
)

watch([model, systemMessage, userMessage], () => {
  queueSelectedPresetAutoSave()
})

watch(
  () => ({ ...settings }),
  () => {
    queueSelectedPresetAutoSave()
  },
  { deep: true },
)

watch(selectedPresetId, (id) => {
  setPresetIdInUrl(id)
  clearPresetAutoSaveTimer()
  if (id) {
    void loadSelectedPreset()
  }
})

onMounted(async () => {
  selectedPresetId.value = getPresetIdFromUrl()
  await reconnectSavedPresetDirectory()
  void loadOpenRouterModels()

  window.addEventListener('focus', syncPresetsFromDirectory)
  window.addEventListener('keydown', handleWindowKeydown)
})

onBeforeUnmount(() => {
  setAutoSync(false)
  clearPresetAutoSaveTimer()
  window.removeEventListener('focus', syncPresetsFromDirectory)
  window.removeEventListener('keydown', handleWindowKeydown)
})
</script>

<template>
  <div class="text-slate-900">
    <div class="mx-auto flex w-full max-w-full flex-col gap-6">
      <header class="flex flex-wrap items-center justify-between gap-4 bg-slate-800 text-white p-6">
        <div>
          <h1 class="text-2xl tracking-tight">OpenRouter Playground</h1>
          <p class="text-sm text-slate-400">Experiment with models, prompts, and reusable local presets.</p>
        </div>
        <button
          type="button"
          class="rounded-xl bg-rose-900 px-4 py-2 text-2xl font-semibold text-white transition hover:bg-slate-700 disabled:cursor-not-allowed disabled:bg-slate-400"
          :disabled="isSending || !canSend"
          @click="sendPrompt"
        >
          {{ isSending ? 'Sending…' : 'Execute Request' }}
        </button>
      </header>

      <section class="grid lg:grid-cols-[1fr_24rem]">
        <article class="bg-white/80 p-5">
          <div class="grid grid-cols-12 gap-4">
            <div class="col-span-8">
              <div class="mb-4 grid gap-4 sm:grid-cols-2">
                <label class="block">
                  <span class="mb-1 block text-sm font-semibold">Model</span>
                  <div class="relative">
                    <input
                      v-model="model"
                      type="text"
                      placeholder="openai/gpt-4.1-mini"
                      class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 outline-none ring-0 transition focus:border-slate-900"
                      @focus="isModelInputFocused = true"
                      @blur="isModelInputFocused = false"
                    />
                    <div
                      v-if="showModelSuggestions"
                      class="absolute z-20 mt-1 max-h-64 w-full overflow-auto rounded-xl border border-slate-200 bg-white p-1 shadow-lg"
                    >
                      <button
                        v-for="entry in filteredModelSuggestions"
                        :key="entry.id"
                        type="button"
                        class="block w-full rounded-lg px-3 py-2 text-left text-sm transition hover:bg-slate-100"
                        @mousedown.prevent="applyModelSuggestion(entry.id)"
                      >
                        <div class="font-semibold text-slate-900">{{ entry.id }}</div>
                        <div v-if="entry.name && entry.name !== entry.id" class="text-xs text-slate-500">{{ entry.name }}</div>
                      </button>
                    </div>
                  </div>
                  <span v-if="isLoadingModels" class="mt-1 block text-xs text-slate-500">Loading model suggestions...</span>
                  <span v-else-if="modelLoadError" class="mt-1 block text-xs text-rose-600">{{ modelLoadError }}</span>
                </label>
              </div>

              <label class="mb-4 block">
                <span class="mb-1 block text-sm font-semibold">System Message</span>
                <CodeEditor v-model="systemMessage" aria-label="System Message" />
              </label>

              <label class="mb-4 block">
                <span class="mb-1 block text-sm font-semibold">User Message</span>
                <CodeEditor v-model="userMessage" aria-label="User Message" />
              </label>

              <div v-if="errorMessage" class="mb-4 rounded-xl border border-rose-300 bg-rose-50 p-3 text-sm text-rose-800">
                {{ errorMessage }}
              </div>
            </div>

            <div class="col-span-4">
              <div class="space-y-4">

                <div>
                  <h2 class="mb-2 text-sm font-semibold">Response Usage</h2>
                  <div class="">
                    <div class="grid gap-3 sm:grid-cols-3 text-[11px]">
                      <div class="rounded-xl border border-sky-100 bg-sky-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-sky-700">Prompt</p>
                        <p class="m-0 p-0 mt-1 font-mono font-bold text-sky-950">{{ formatUsageNumber(responseUsage?.promptTokens ?? null) }} tokens</p>
                      </div>
                      <div class="rounded-xl border border-indigo-100 bg-indigo-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-indigo-700">Completion</p>
                        <p class="mt-1 font-mono font-bold text-indigo-950">{{ formatUsageNumber(responseUsage?.completionTokens ?? null) }} tokens</p>
                      </div>
                      <div class="rounded-xl border border-emerald-100 bg-emerald-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-emerald-700">Total</p>
                        <p class="mt-1 font-mono font-bold text-emerald-950">{{ formatUsageNumber(responseUsage?.totalTokens ?? null) }} tokens</p>
                      </div>
                      <div class="rounded-xl border border-amber-100 bg-amber-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-amber-700">Cost</p>
                        <p class="mt-1 font-mono font-bold text-amber-950">${{ formatUsageCost(responseUsage?.cost ?? null) }}</p>
                      </div>
                      <div class="rounded-xl border border-slate-100 bg-slate-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-slate-700">Cached</p>
                        <p class="mt-1 font-mono font-bold text-slate-950">{{ formatUsageNumber(responseUsage?.cachedTokens ?? null) }}</p>
                      </div>
                      <div class="rounded-xl border border-fuchsia-100 bg-fuchsia-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-fuchsia-700">Time</p>
                        <p class="mt-1 font-mono font-bold text-fuchsia-950">{{ formatUsageDuration(responseUsage?.requestDurationSeconds ?? null) }}s</p>
                      </div>
                    </div>
                  </div>
                </div>

                <div>
                  <h2 class="mb-2 text-sm font-semibold">Response (Text)</h2>
                  <pre class="min-h-52 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100">{{ responseText }}</pre>
                </div>

                <div>
                  <h2 class="mb-2 text-sm font-semibold">Response (JSON)</h2>
                  <pre class="min-h-52 overflow-auto rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100">{{ responseJson }}</pre>
                </div>
              </div>
            </div>
          </div>

        </article>

        <aside class="bg-white/80 p-4">
          <h2 class="mb-2 text-base font-black tracking-tight">Preset Manager</h2>
          <p class="mb-4 text-xs text-slate-600">Presets are saved as JSON files in a synced local directory.</p>

          <div class="mb-3 rounded-lg border border-slate-200 bg-slate-50 p-3 text-xs text-slate-700">
            Directory: <strong>{{ directoryLabel }}</strong>
          </div>

          <div class="mb-4 flex gap-2">
            <button
              type="button"
              class="flex-1 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed"
              :disabled="!canUseDirectoryApi"
              @click="hasConnectedDirectory ? disconnectPresetDirectory() : connectPresetDirectory()"
            >
              {{ hasConnectedDirectory ? 'Disconnect Directory' : 'Connect Directory' }}
            </button>
          </div>

          <label class="mb-2 block">
            <span class="mb-1 block text-xs font-semibold">Preset Name</span>
            <input
              v-model="presetName"
              type="text"
              placeholder="My coding preset"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
              @keydown.enter.prevent="renameSelectedPreset"
            />
          </label>

          <button
            type="button"
            class="mb-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed"
            :disabled="!canRenameSelectedPreset"
            @click="renameSelectedPreset"
          >
            Rename Selected Preset
          </button>

          <button
            type="button"
            class="mb-4 w-full rounded-xl bg-emerald-600 px-3 py-2 text-sm font-semibold text-white transition hover:bg-emerald-500 disabled:cursor-not-allowed disabled:bg-emerald-300"
            :disabled="!presetDirectoryHandle"
            @click="savePreset"
          >
            Save Current As Preset
          </button>

          <label class="mb-2 block">
            <span class="mb-1 block text-xs font-semibold">Saved Presets</span>
            <select
              v-model="selectedPresetId"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
            >
              <option value="">Select a preset</option>
              <option v-for="preset in presets" :key="preset.id" :value="preset.id">
                {{ preset.name }}
              </option>
            </select>
          </label>

          <div class="flex gap-2">
            <button
              type="button"
              class="flex-1 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed"
              :disabled="!selectedPreset"
              @click="loadSelectedPreset"
            >
              Load
            </button>
            <button
              type="button"
              class="flex-1 rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-700 transition hover:border-rose-300 disabled:cursor-not-allowed"
              :disabled="!selectedPreset || !presetDirectoryHandle"
              @click="deleteSelectedPreset"
            >
              Delete
            </button>
          </div>

          <div class="mt-4 border-t border-slate-200 pt-4">
            <h3 class="mb-3 text-sm font-semibold">Request Settings</h3>
            <div class="grid gap-3">
              <label>
                <span class="mb-1 block text-xs font-semibold">API Key</span>
                <input
                  v-model="settings.apiKey"
                  type="password"
                  placeholder="sk-or-v1-..."
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
                />
              </label>

              <label>
                <span class="mb-1 block text-xs font-semibold">Temperature (0-2)</span>
                <input
                  v-model.number="settings.temperature"
                  type="number"
                  min="0"
                  max="2"
                  step="0.1"
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
                />
              </label>

              <label>
                <span class="mb-1 block text-xs font-semibold">Top P (0-1)</span>
                <input
                  v-model.number="settings.topP"
                  type="number"
                  min="0"
                  max="1"
                  step="0.05"
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
                />
              </label>

              <label class="flex items-center justify-between gap-3">
                <span class="text-xs font-semibold">Reasoning</span>
                <span class="relative inline-flex cursor-pointer items-center">
                  <input v-model="settings.reasoningEnabled" type="checkbox" class="peer sr-only" />
                  <span
                    class="h-6 w-11 rounded-full bg-slate-300 transition peer-checked:bg-slate-900 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-slate-400"
                  />
                  <span
                    class="pointer-events-none absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition peer-checked:translate-x-5"
                  />
                </span>
              </label>

              <label>
                <span class="mb-1 block text-xs font-semibold">Reasoning Effort</span>
                <select
                  v-model="settings.reasoningEffort"
                  :disabled="!settings.reasoningEnabled"
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900"
                >
                  <option value="low">low</option>
                  <option value="medium">medium</option>
                  <option value="high">high</option>
                </select>
              </label>
            </div>
          </div>

          <p v-if="!canUseDirectoryApi" class="mt-3 text-xs text-amber-700">
            Your browser does not support the File System Access API for directory sync.
          </p>
        </aside>
      </section>
    </div>
  </div>
</template>
