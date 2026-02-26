<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import CodeEditor from './components/CodeEditor.vue'

type ReasoningEffort = 'low' | 'medium' | 'high'
type VariableInputType = 'text' | 'textarea'

interface RequestSettings {
  apiKey: string
  temperature: number
  topP: number
  reasoningEnabled: boolean
  reasoningEffort: ReasoningEffort
}

interface PromptVariable {
  name: string
  value: string
  inputType: VariableInputType
}

interface PromptPreset {
  id: string
  name: string
  model: string
  systemMessage: string
  userMessage: string
  variables: PromptVariable[]
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
const THEME_STORAGE_KEY = 'theme-preference'
const DEFAULT_MODEL = 'openai/gpt-4.1-mini'
const DEFAULT_SYSTEM_MESSAGE = 'You are a helpful assistant.'
const DEFAULT_USER_MESSAGE = ''
const DEFAULT_SETTINGS: RequestSettings = {
  apiKey: '',
  temperature: 0.7,
  topP: 1,
  reasoningEnabled: true,
  reasoningEffort: 'medium',
}

const model = ref(DEFAULT_MODEL)
const compareModel = ref('openai/gpt-4.1')
const compareMode = ref(false)
const systemMessage = ref(DEFAULT_SYSTEM_MESSAGE)
const userMessage = ref(DEFAULT_USER_MESSAGE)
const promptVariables = ref<PromptVariable[]>([])
const responseText = ref('')
const responseReasoning = ref('')
const responseJson = ref('')
const responseUsage = ref<OpenRouterUsage | null>(null)
const compareResponseText = ref('')
const compareResponseReasoning = ref('')
const compareResponseJson = ref('')
const compareResponseUsage = ref<OpenRouterUsage | null>(null)
const compareResponseError = ref('')
const errorMessage = ref('')
const isDarkMode = ref(false)
const isSending = ref(false)
const activeRequestController = ref<AbortController | null>(null)
const isModelInputFocused = ref(false)
const isLoadingModels = ref(false)
const modelLoadError = ref('')
const openRouterModels = ref<OpenRouterModel[]>([])
const copyResponseTextState = ref<'idle' | 'copied' | 'error'>('idle')
const responseTextViewMode = ref<'raw' | 'preview'>('raw')
let presetAutoSyncTimer: ReturnType<typeof setInterval> | null = null
let presetAutoSaveTimer: ReturnType<typeof setTimeout> | null = null
let copyResponseTextTimer: ReturnType<typeof setTimeout> | null = null
const suppressPresetAutoSave = ref(false)

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
const filteredModelSuggestions = computed(() => {
  const query = model.value.trim().toLowerCase()
  const source = openRouterModels.value

  if (!query) {
    return source.slice(0, 12)
  }

  return source.filter((entry) => entry.id.toLowerCase().includes(query) || entry.name.toLowerCase().includes(query)).slice(0, 12)
})
const showModelSuggestions = computed(() => isModelInputFocused.value && filteredModelSuggestions.value.length > 0)

const canSend = computed(
  () =>
    !!settings.apiKey.trim() &&
    !!model.value.trim() &&
    !!userMessage.value.trim() &&
    (!compareMode.value || !!compareModel.value.trim()),
)

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

function toVariableInputType(value: unknown): VariableInputType {
  return value === 'text' ? 'text' : 'textarea'
}

function toPromptVariables(value: unknown): PromptVariable[] {
  if (!Array.isArray(value)) {
    return []
  }

  return value
    .filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === 'object')
    .map((entry) => ({
      name: typeof entry.name === 'string' ? entry.name : '',
      value: typeof entry.value === 'string' ? entry.value : '',
      inputType: toVariableInputType(entry.inputType),
    }))
    .filter((entry) => !!entry.name.trim())
}

function snapshotVariables(): PromptVariable[] {
  return promptVariables.value
    .map((entry) => ({
      name: entry.name.trim(),
      value: entry.value,
      inputType: entry.inputType,
    }))
    .filter((entry) => !!entry.name)
}

function applyVariables(nextVariables: PromptVariable[]) {
  promptVariables.value = nextVariables.map((entry) => ({
    name: entry.name,
    value: entry.value,
    inputType: toVariableInputType(entry.inputType),
  }))
}

function interpolateVariables(template: string) {
  const replacements = new Map<string, string>()

  for (const entry of promptVariables.value) {
    const key = entry.name.trim()
    if (!key) {
      continue
    }
    replacements.set(key, entry.value)
  }

  return template.replace(/\{([a-zA-Z_][a-zA-Z0-9_]*)\}/g, (token, key) => {
    if (!replacements.has(key)) {
      return token
    }
    return replacements.get(key) ?? ''
  })
}

function addVariable() {
  promptVariables.value = [...promptVariables.value, { name: '', value: '', inputType: 'text' }]
}

function removeVariable(index: number) {
  promptVariables.value = promptVariables.value.filter((_, itemIndex) => itemIndex !== index)
}

function areVariablesEqual(left: PromptVariable[], right: PromptVariable[]) {
  if (left.length !== right.length) {
    return false
  }

  return left.every(
    (entry, index) =>
      entry.name === right[index]?.name &&
      entry.value === right[index]?.value &&
      entry.inputType === right[index]?.inputType,
  )
}

function toggleVariableInputType(index: number) {
  const variable = promptVariables.value[index]
  if (!variable) {
    return
  }

  variable.inputType = variable.inputType === 'textarea' ? 'text' : 'textarea'
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

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function sanitizeMarkdownHref(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) {
    return null
  }
  if (/^https?:\/\//i.test(trimmed) || /^mailto:/i.test(trimmed)) {
    return trimmed
  }
  return null
}

function renderMarkdownInline(value: string): string {
  const inlineCodeMatches: string[] = []
  let rendered = value.replace(/`([^`\n]+?)`/g, (_, code: string) => {
    const token = `@@INLINE_CODE_${inlineCodeMatches.length}@@`
    inlineCodeMatches.push(`<code>${escapeHtml(code)}</code>`)
    return token
  })
  rendered = escapeHtml(rendered)

  rendered = rendered.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label: string, href: string) => {
    const safeHref = sanitizeMarkdownHref(href)
    if (!safeHref) {
      return `${label} (${href})`
    }
    return `<a href="${escapeHtml(safeHref)}" target="_blank" rel="noopener noreferrer">${label}</a>`
  })

  rendered = rendered
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/__([^_]+)__/g, '<strong>$1</strong>')
    .replace(/(^|[^\*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>')
    .replace(/(^|[^_])_([^_\n]+)_(?!_)/g, '$1<em>$2</em>')

  for (let index = 0; index < inlineCodeMatches.length; index += 1) {
    rendered = rendered.replace(`@@INLINE_CODE_${index}@@`, inlineCodeMatches[index] ?? '')
  }

  return rendered
}

function renderMarkdownToHtml(value: string): string {
  const lines = value.replace(/\r\n/g, '\n').split('\n')
  const blocks: string[] = []
  let index = 0

  const isBlank = (line: string) => line.trim().length === 0
  const isFenceStart = (line: string) => /^```/.test(line.trim())
  const isHeading = (line: string) => /^(#{1,6})\s+/.test(line)
  const isHorizontalRule = (line: string) => /^\s*(\*{3,}|-{3,}|_{3,})\s*$/.test(line)
  const isQuoteLine = (line: string) => /^\s*>\s?/.test(line)
  const isUnorderedListLine = (line: string) => /^\s*[-*+]\s+/.test(line)
  const isOrderedListLine = (line: string) => /^\s*\d+\.\s+/.test(line)
  const startsBlock = (line: string) =>
    isFenceStart(line) ||
    isHeading(line) ||
    isHorizontalRule(line) ||
    isQuoteLine(line) ||
    isUnorderedListLine(line) ||
    isOrderedListLine(line)

  while (index < lines.length) {
    const line = lines[index] ?? ''

    if (isBlank(line)) {
      index += 1
      continue
    }

    if (isFenceStart(line)) {
      const language = (line.trim().match(/^```([\w-]+)?/)?.[1] ?? '').toLowerCase()
      index += 1
      const codeLines: string[] = []
      while (index < lines.length && !/^```/.test(lines[index]?.trim() ?? '')) {
        codeLines.push(lines[index] ?? '')
        index += 1
      }
      if (index < lines.length) {
        index += 1
      }
      blocks.push(
        `<pre><code${language ? ` class="language-${escapeHtml(language)}"` : ''}>${escapeHtml(codeLines.join('\n'))}</code></pre>`,
      )
      continue
    }

    const headingMatch = line.match(/^(#{1,6})\s+(.*)$/)
    if (headingMatch) {
      const level = headingMatch[1]?.length ?? 1
      const text = headingMatch[2] ?? ''
      blocks.push(`<h${level}>${renderMarkdownInline(text)}</h${level}>`)
      index += 1
      continue
    }

    if (isHorizontalRule(line)) {
      blocks.push('<hr />')
      index += 1
      continue
    }

    if (isQuoteLine(line)) {
      const quoteLines: string[] = []
      while (index < lines.length && isQuoteLine(lines[index] ?? '')) {
        quoteLines.push((lines[index] ?? '').replace(/^\s*>\s?/, ''))
        index += 1
      }
      blocks.push(`<blockquote>${renderMarkdownInline(quoteLines.join('\n')).replace(/\n/g, '<br />')}</blockquote>`)
      continue
    }

    if (isUnorderedListLine(line)) {
      const listItems: string[] = []
      while (index < lines.length && isUnorderedListLine(lines[index] ?? '')) {
        const listLine = lines[index] ?? ''
        listItems.push(`<li>${renderMarkdownInline(listLine.replace(/^\s*[-*+]\s+/, ''))}</li>`)
        index += 1
      }
      blocks.push(`<ul>${listItems.join('')}</ul>`)
      continue
    }

    if (isOrderedListLine(line)) {
      const listItems: string[] = []
      const firstMatch = line.match(/^\s*(\d+)\.\s+/)
      const start = Number(firstMatch?.[1] ?? '1')
      while (index < lines.length && isOrderedListLine(lines[index] ?? '')) {
        const listLine = lines[index] ?? ''
        listItems.push(`<li>${renderMarkdownInline(listLine.replace(/^\s*\d+\.\s+/, ''))}</li>`)
        index += 1
      }
      const startAttr = Number.isFinite(start) && start > 1 ? ` start="${start}"` : ''
      blocks.push(`<ol${startAttr}>${listItems.join('')}</ol>`)
      continue
    }

    const paragraphLines: string[] = []
    while (index < lines.length && !isBlank(lines[index] ?? '') && !startsBlock(lines[index] ?? '')) {
      paragraphLines.push(lines[index] ?? '')
      index += 1
    }
    blocks.push(`<p>${renderMarkdownInline(paragraphLines.join('\n')).replace(/\n/g, '<br />')}</p>`)
  }

  return blocks.join('')
}

const renderedResponseTextHtml = computed(() => renderMarkdownToHtml(responseText.value))

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

function applyThemeClass(isDark: boolean) {
  if (typeof document === 'undefined') {
    return
  }
  document.documentElement.classList.toggle('dark', isDark)
}

function loadThemePreference() {
  if (typeof window === 'undefined') {
    return false
  }
  const storedTheme = window.localStorage.getItem(THEME_STORAGE_KEY)
  if (storedTheme === 'dark') {
    return true
  }
  if (storedTheme === 'light') {
    return false
  }
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false
}

function toggleDarkMode() {
  isDarkMode.value = !isDarkMode.value
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
        variables: toPromptVariables(parsed.variables),
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
        variables: preset.variables,
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

  const defaultName = selectedPreset.value?.name || 'Untitled preset'
  const promptedName = window.prompt('Enter the name for the new preset:', defaultName)
  if (promptedName === null) {
    return
  }

  const name = promptedName.trim() || defaultName
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
    variables: snapshotVariables(),
    settings: snapshotSettings(),
    updatedAt: now,
  }

  try {
    await writePreset(preset)
    selectedPresetId.value = preset.id
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to save preset.'
  }
}

async function createNewPreset() {
  if (!presetDirectoryHandle.value) {
    errorMessage.value = 'Connect a preset directory first.'
    return
  }

  if (!selectedPreset.value) {
    const shouldContinue = window.confirm(
      'No preset is currently selected. Creating a new preset will discard your current unsaved changes. Continue?',
    )
    if (!shouldContinue) {
      return
    }
  }

  const promptedName = window.prompt('Enter the name for the new preset:', 'New preset')
  if (promptedName === null) {
    return
  }

  const name = promptedName.trim() || 'New preset'
  const now = new Date().toISOString()
  const id = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}`
  const filename = `${id}-${cleanFilename(name)}.json`

  const preset: PromptPreset = {
    id,
    filename,
    name,
    model: DEFAULT_MODEL,
    systemMessage: DEFAULT_SYSTEM_MESSAGE,
    userMessage: DEFAULT_USER_MESSAGE,
    variables: [],
    settings: { ...DEFAULT_SETTINGS },
    updatedAt: now,
  }

  try {
    await writePreset(preset)
    selectedPresetId.value = preset.id
    await syncPresetsFromDirectory()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : 'Unable to create preset.'
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
  applyVariables(selectedPreset.value.variables)
  applySettings(selectedPreset.value.settings)
  await nextTick()
  suppressPresetAutoSave.value = false
}

async function deleteSelectedPreset() {
  if (!presetDirectoryHandle.value || !selectedPreset.value) {
    return
  }

  const shouldDelete = window.confirm(`Delete preset "${selectedPreset.value.name}"? This cannot be undone.`)
  if (!shouldDelete) {
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

  const promptedName = window.prompt('Enter the new name for the selected preset:', selectedPreset.value.name)
  if (promptedName === null) {
    return
  }

  const nextName = promptedName.trim()
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

async function runPromptRequest(targetModel: string, messages: Array<{ role: 'system' | 'user'; content: string }>) {
  const requestStartedAt = performance.now()
  const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    signal: activeRequestController.value?.signal,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${settings.apiKey.trim()}`,
    },
    body: JSON.stringify({
      model: targetModel,
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
  const reasoning = payload?.choices?.[0]?.message?.reasoning
  return {
    text: toTextContent(content) || '[No text content in model response]',
    reasoning: toTextContent(reasoning),
    json: JSON.stringify(payload, null, 2),
    usage: extractUsage(payload, requestDurationSeconds),
  }
}

function cancelRequest() {
  if (!isSending.value || !activeRequestController.value) {
    return
  }
  activeRequestController.value.abort()
}

async function sendPrompt() {
  if (isSending.value || !canSend.value) {
    return
  }

  const requestController = new AbortController()
  activeRequestController.value = requestController
  isSending.value = true
  errorMessage.value = ''
  responseUsage.value = null
  compareResponseUsage.value = null
  compareResponseError.value = ''
  compareResponseText.value = ''
  compareResponseReasoning.value = ''
  compareResponseJson.value = ''

  try {
    const resolvedSystemMessage = interpolateVariables(systemMessage.value).trim()
    const resolvedUserMessage = interpolateVariables(userMessage.value).trim()
    const messages: Array<{ role: 'system' | 'user'; content: string }> = []
    if (resolvedSystemMessage) {
      messages.push({ role: 'system', content: resolvedSystemMessage })
    }
    messages.push({ role: 'user', content: resolvedUserMessage })

    const primaryModel = model.value.trim()
    const secondaryModel = compareModel.value.trim()

    const [primaryResult, secondaryResult] = await Promise.all([
      runPromptRequest(primaryModel, messages),
      compareMode.value
        ? runPromptRequest(secondaryModel, messages)
            .then((result) => ({ ...result, error: '' }))
            .catch((error) => ({
              text: '',
              reasoning: '',
              json: '',
              usage: null,
              error: error instanceof Error ? error.message : 'Request failed.',
            }))
        : Promise.resolve(null),
    ])

    responseText.value = primaryResult.text
    responseReasoning.value = primaryResult.reasoning
    responseJson.value = primaryResult.json
    responseUsage.value = primaryResult.usage

    if (secondaryResult) {
      compareResponseText.value = secondaryResult.text
      compareResponseReasoning.value = secondaryResult.reasoning
      compareResponseJson.value = secondaryResult.json
      compareResponseUsage.value = secondaryResult.usage
      compareResponseError.value = secondaryResult.error
      if (secondaryResult.error) {
        errorMessage.value = 'One model request failed. See compare result for details.'
      }
    }
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') {
      errorMessage.value = 'Request canceled.'
    } else {
      errorMessage.value = error instanceof Error ? error.message : 'Request failed.'
    }
  } finally {
    if (activeRequestController.value === requestController) {
      activeRequestController.value = null
    }
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

function clearCopyResponseTextTimer() {
  if (copyResponseTextTimer) {
    clearTimeout(copyResponseTextTimer)
    copyResponseTextTimer = null
  }
}

async function copyResponseText() {
  if (!responseText.value.trim()) {
    return
  }

  try {
    await navigator.clipboard.writeText(responseText.value)
    copyResponseTextState.value = 'copied'
  } catch {
    copyResponseTextState.value = 'error'
  }

  clearCopyResponseTextTimer()
  copyResponseTextTimer = setTimeout(() => {
    copyResponseTextState.value = 'idle'
  }, 1500)
}

function hasSelectedPresetChanges() {
  if (!selectedPreset.value) {
    return false
  }

  return (
    model.value !== selectedPreset.value.model ||
    systemMessage.value !== selectedPreset.value.systemMessage ||
    userMessage.value !== selectedPreset.value.userMessage ||
    !areVariablesEqual(promptVariables.value, selectedPreset.value.variables) ||
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
    variables: snapshotVariables(),
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
  promptVariables,
  () => {
    queueSelectedPresetAutoSave()
  },
  { deep: true },
)

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

watch(isDarkMode, (isDark) => {
  applyThemeClass(isDark)
  if (typeof window !== 'undefined') {
    window.localStorage.setItem(THEME_STORAGE_KEY, isDark ? 'dark' : 'light')
  }
})

onMounted(async () => {
  isDarkMode.value = loadThemePreference()
  applyThemeClass(isDarkMode.value)

  selectedPresetId.value = getPresetIdFromUrl()
  await reconnectSavedPresetDirectory()
  void loadOpenRouterModels()

  window.addEventListener('focus', syncPresetsFromDirectory)
  window.addEventListener('keydown', handleWindowKeydown)
})

onBeforeUnmount(() => {
  setAutoSync(false)
  clearPresetAutoSaveTimer()
  clearCopyResponseTextTimer()
  window.removeEventListener('focus', syncPresetsFromDirectory)
  window.removeEventListener('keydown', handleWindowKeydown)
})
</script>

<template>
  <div class="min-h-screen text-slate-900 transition-colors dark:text-slate-100 bg-white/80 dark:bg-slate-800">
    <div class="mx-auto flex w-full max-w-full flex-col">
      <header class="flex flex-wrap items-center justify-between gap-4 bg-slate-800 p-6 text-white dark:bg-slate-950">
        <div>
          <h1 class="text-2xl tracking-tight">OpenRouter Playground</h1>
          <p class="text-sm text-slate-400 dark:text-slate-300">Experiment with models, prompts, and reusable local presets. Use <code>Cmd+R</code>/<code>Ctrl+R</code> shortcut to execute requests.</p>
        </div>
        <div class="flex items-center gap-3">
          <button
            type="button"
            class="rounded-xl border border-slate-500 bg-slate-700 px-3 py-2 text-sm font-semibold text-slate-100 transition hover:bg-slate-600 dark:border-slate-400 dark:bg-slate-800 dark:hover:bg-slate-700"
            @click="toggleDarkMode"
          >
            {{ isDarkMode ? 'Light Mode' : 'Dark Mode' }}
          </button>
          <button
            type="button"
            class="rounded-xl px-4 py-2 text-2xl font-semibold text-white transition disabled:cursor-not-allowed disabled:bg-slate-400 dark:disabled:bg-slate-600"
            :class="
              isSending
                ? 'bg-rose-700 hover:bg-rose-600 dark:bg-rose-700 dark:hover:bg-rose-600'
                : 'bg-emerald-700 hover:bg-emerald-600 dark:bg-emerald-700 dark:hover:bg-emerald-600'
            "
            :disabled="!isSending && !canSend"
            @click="isSending ? cancelRequest() : sendPrompt()"
          >
            {{ isSending ? 'Cancel' : 'Execute Request' }}
          </button>
        </div>
      </header>

      <section class="grid lg:grid-cols-[2fr_20rem] ">
        <article class="p-5">
          <h1 class="text-2xl mb-4">{{ selectedPreset?.name || "(Unsaved Preset) Your changes will not be saved"  }}</h1>
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
                      class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 outline-none ring-0 transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                      @focus="isModelInputFocused = true"
                      @blur="isModelInputFocused = false"
                    />
                    <div
                      v-if="showModelSuggestions"
                      class="absolute z-20 mt-1 max-h-64 w-full overflow-auto rounded-xl border border-slate-200 bg-white p-1 shadow-lg dark:border-slate-700 dark:bg-slate-900"
                    >
                      <button
                        v-for="entry in filteredModelSuggestions"
                        :key="entry.id"
                        type="button"
                        class="block w-full rounded-lg px-3 py-2 text-left text-sm transition hover:bg-slate-100 dark:hover:bg-slate-800"
                        @mousedown.prevent="applyModelSuggestion(entry.id)"
                      >
                        <div class="font-semibold text-slate-900 dark:text-slate-100">{{ entry.id }}</div>
                        <div v-if="entry.name && entry.name !== entry.id" class="text-xs text-slate-500 dark:text-slate-400">{{ entry.name }}</div>
                      </button>
                    </div>
                  </div>
                  <span v-if="isLoadingModels" class="mt-1 block text-xs text-slate-500 dark:text-slate-400">Loading model suggestions...</span>
                  <span v-else-if="modelLoadError" class="mt-1 block text-xs text-rose-600">{{ modelLoadError }}</span>
                </label>
                <div class="rounded-xl border border-slate-200 p-3 dark:border-slate-700">
                  <label class="flex items-center justify-between gap-3">
                    <span class="text-sm font-semibold">Compare Mode</span>
                    <span class="relative inline-flex cursor-pointer items-center">
                      <input v-model="compareMode" type="checkbox" class="peer sr-only" />
                      <span
                        class="h-6 w-11 rounded-full bg-slate-300 transition peer-checked:bg-slate-900 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-slate-400 dark:bg-slate-700 dark:peer-checked:bg-slate-300 dark:peer-focus:ring-slate-500"
                      />
                      <span
                        class="pointer-events-none absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition peer-checked:translate-x-5 dark:bg-slate-950"
                      />
                    </span>
                  </label>
                  <label v-if="compareMode" class="mt-3 block">
                    <span class="mb-1 block text-xs font-semibold">Compare Against</span>
                    <input
                      v-model="compareModel"
                      type="text"
                      placeholder="openai/gpt-4.1"
                      class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 outline-none ring-0 transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                    />
                  </label>
                </div>
              </div>

              <label class="mb-4 block">
                <span class="mb-1 block text-sm font-semibold">System Message</span>
                <CodeEditor v-model="systemMessage" :dark="isDarkMode" aria-label="System Message" @mod-enter="sendPrompt" />
              </label>

              <label class="mb-4 block">
                <span class="mb-1 block text-sm font-semibold">User Message</span>
                <CodeEditor v-model="userMessage" :dark="isDarkMode" aria-label="User Message" @mod-enter="sendPrompt" />
              </label>

              <div class="mb-4 rounded-xl border border-slate-200 p-3 dark:border-slate-700">
                <div class="mb-2 flex items-center justify-between gap-2">
                  <span class="text-sm font-semibold">Variables</span>
                  <button
                    type="button"
                    class="rounded-lg border border-slate-300 bg-white px-2 py-1 text-xs font-semibold transition hover:border-slate-400 dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
                    @click="addVariable"
                  >
                    Add Variable
                  </button>
                </div>
                <p class="mb-3 text-xs text-slate-600 dark:text-slate-400">
                  Use placeholders like <code>{my_var}</code> in System/User messages.
                </p>
                <div v-if="promptVariables.length" class="space-y-2">
                  <div
                    v-for="(entry, index) in promptVariables"
                    :key="index"
                    class="grid grid-cols-12 gap-2"
                  >
                    <div class="col-span-3">
                      <input
                        v-model="entry.name"
                        type="text"
                        placeholder="my_var"
                        class="w-full rounded-lg border border-slate-300 bg-white px-2 py-1 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                      />
                    </div>
                    <div class="col-span-8">
                      <div>
                        <textarea
                          v-if="entry.inputType === 'textarea'"
                          v-model="entry.value"
                          placeholder="Variable value"
                          rows="3"
                          class="w-full rounded-lg border border-slate-300 bg-white px-2 py-1 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                        ></textarea>
                        <input
                          v-else
                          v-model="entry.value"
                          type="text"
                          placeholder="Variable value"
                          class="w-full mb-1 rounded-lg border border-slate-300 bg-white px-2 py-1 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                        />
                      </div>
                      <div class="flex justify-end">
                        <button
                          type="button"
                          class="rounded-md border border-slate-300 bg-white px-2 py-0.5 text-[11px] font-semibold transition hover:border-slate-400 dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
                          @click="toggleVariableInputType(index)"
                        >
                          {{ entry.inputType === 'textarea' ? 'Use Text Input' : 'Use Textarea' }}
                        </button>
                      </div>
                    </div>
                    <div class="col-span-1">
                      <button
                        type="button"
                        class="col-span-1 rounded-lg border border-rose-200 bg-rose-50 px-2 py-1 text-xs font-semibold text-rose-700 transition hover:border-rose-300"
                        @click="removeVariable(index)"
                      >
                        X
                      </button>
                    </div>
                  </div>
                </div>
                <p v-else class="text-xs text-slate-500 dark:text-slate-400">No variables defined.</p>
              </div>

              <div v-if="errorMessage" class="mb-4 rounded-xl border border-rose-300 bg-rose-50 p-3 text-sm text-rose-800">
                {{ errorMessage }}
              </div>
            </div>

            <div class="col-span-4">
              <div class="space-y-4">
                <template v-if="!compareMode">
                  <div>
                    <h2 class="mb-2 text-sm font-semibold">Response Usage</h2>
                    <div class="grid gap-3 sm:grid-cols-3 text-[11px]">
                      <div class="rounded-xl border border-sky-100 bg-sky-50/70 py-1 px-2">
                        <p class="font-semibold uppercase tracking-[0.08em] text-sky-700">Prompt</p>
                        <p class="m-0 mt-1 p-0 font-mono font-bold text-sky-950">{{ formatUsageNumber(responseUsage?.promptTokens ?? null) }} tokens</p>
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

                  <div>
                    <div class="mb-2 flex items-center justify-between gap-2">
                      <h2 class="text-sm font-semibold">Response (Text)</h2>
                      <div class="flex items-center gap-2">
                        <div class="inline-flex overflow-hidden rounded-md border border-slate-300 dark:border-slate-700">
                          <button
                            type="button"
                            class="bg-white px-2 py-1 text-[11px] font-semibold transition dark:bg-slate-950"
                            :class="responseTextViewMode === 'raw' ? 'bg-slate-900 text-slate-800 dark:bg-slate-200 dark:text-slate-300' : 'text-slate-400 hover:bg-slate-100 dark:text-slate-600 dark:hover:bg-slate-800'"
                            @click="responseTextViewMode = 'raw'"
                          >
                            Raw
                          </button>
                          <button
                            type="button"
                            class="bg-white px-2 py-1 text-[11px] font-semibold transition dark:bg-slate-950"
                            :class="responseTextViewMode === 'preview' ? 'bg-slate-900 text-slate-800 dark:bg-slate-200 dark:text-slate-300' : 'text-slate-400 hover:bg-slate-100 dark:text-slate-600 dark:hover:bg-slate-800'"
                            @click="responseTextViewMode = 'preview'"
                          >
                            Preview
                          </button>
                        </div>
                        <button
                          type="button"
                          class="rounded-md border border-slate-300 bg-white px-2 py-1 text-[11px] font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
                          :disabled="!responseText.trim()"
                          @click="copyResponseText"
                        >
                          {{
                            copyResponseTextState === 'copied'
                              ? 'Copied'
                              : copyResponseTextState === 'error'
                                ? 'Copy failed'
                                : 'Copy'
                          }}
                        </button>
                      </div>
                    </div>
                    <pre
                      v-if="responseTextViewMode === 'raw'"
                      class="min-h-52 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950"
                    >{{ responseText }}</pre>
                    <div
                      v-else
                      class="markdown-preview min-h-52 rounded-xl border border-slate-200 bg-white p-3 text-sm text-slate-900 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-100"
                      v-html="renderedResponseTextHtml"
                    ></div>
                  </div>

                  <div>
                    <h2 class="mb-2 text-sm font-semibold">Reasoning</h2>
                    <pre class="min-h-52 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ responseReasoning }}</pre>
                  </div>

                  <div>
                    <h2 class="mb-2 text-sm font-semibold">Response (JSON)</h2>
                    <pre class="min-h-52 overflow-auto rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ responseJson }}</pre>
                  </div>
                </template>

                <template v-else>
                  <div class="grid grid-cols-12">
                    <div class="col-span-6">
                        <div class="space-y-4 rounded-xl border border-slate-200 p-3 dark:border-slate-700">
                        <h2 class="text-sm font-semibold">Model A: {{ model }}</h2>
                        <div class="grid gap-2 sm:grid-cols-2 text-[11px]">
                          <div class="rounded-xl border border-sky-100 bg-sky-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-sky-700">Prompt</p>
                            <p class="mt-1 font-mono font-bold text-sky-950">{{ formatUsageNumber(responseUsage?.promptTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-indigo-100 bg-indigo-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-indigo-700">Completion</p>
                            <p class="mt-1 font-mono font-bold text-indigo-950">{{ formatUsageNumber(responseUsage?.completionTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-emerald-100 bg-emerald-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-emerald-700">Total</p>
                            <p class="mt-1 font-mono font-bold text-emerald-950">{{ formatUsageNumber(responseUsage?.totalTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-fuchsia-100 bg-fuchsia-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-fuchsia-700">Time</p>
                            <p class="mt-1 font-mono font-bold text-fuchsia-950">{{ formatUsageDuration(responseUsage?.requestDurationSeconds ?? null) }}s</p>
                          </div>
                        </div>
                        <h3 class="text-xs font-semibold">Response</h3>
                        <pre class="min-h-40 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ responseText }}</pre>
                        <h3 class="text-xs font-semibold">Reasoning</h3>
                        <pre class="min-h-40 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ responseReasoning }}</pre>
                        <h3 class="text-xs font-semibold">JSON</h3>
                        <pre class="min-h-40 overflow-auto rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ responseJson }}</pre>
                      </div>
                    </div>

                    <div class="col-span-6">
                      <div class="space-y-4 rounded-xl border border-slate-200 p-3 dark:border-slate-700">
                        <h2 class="text-sm font-semibold">Model B: {{ compareModel }}</h2>
                        <div class="grid gap-2 sm:grid-cols-2 text-[11px]">
                          <div class="rounded-xl border border-sky-100 bg-sky-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-sky-700">Prompt</p>
                            <p class="mt-1 font-mono font-bold text-sky-950">{{ formatUsageNumber(compareResponseUsage?.promptTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-indigo-100 bg-indigo-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-indigo-700">Completion</p>
                            <p class="mt-1 font-mono font-bold text-indigo-950">{{ formatUsageNumber(compareResponseUsage?.completionTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-emerald-100 bg-emerald-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-emerald-700">Total</p>
                            <p class="mt-1 font-mono font-bold text-emerald-950">{{ formatUsageNumber(compareResponseUsage?.totalTokens ?? null) }}</p>
                          </div>
                          <div class="rounded-xl border border-fuchsia-100 bg-fuchsia-50/70 py-1 px-2">
                            <p class="font-semibold uppercase tracking-[0.08em] text-fuchsia-700">Time</p>
                            <p class="mt-1 font-mono font-bold text-fuchsia-950">{{ formatUsageDuration(compareResponseUsage?.requestDurationSeconds ?? null) }}s</p>
                          </div>
                        </div>
                        <div v-if="compareResponseError" class="rounded-xl border border-rose-300 bg-rose-50 p-2 text-xs text-rose-800">
                          {{ compareResponseError }}
                        </div>
                        <h3 class="text-xs font-semibold">Response</h3>
                        <pre class="min-h-40 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ compareResponseText }}</pre>
                        <h3 class="text-xs font-semibold">Reasoning</h3>
                        <pre class="min-h-40 whitespace-pre-wrap rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ compareResponseReasoning }}</pre>
                        <h3 class="text-xs font-semibold">JSON</h3>
                        <pre class="min-h-40 overflow-auto rounded-xl border border-slate-200 bg-slate-950 p-3 text-xs text-slate-100 dark:border-slate-700 dark:bg-slate-950">{{ compareResponseJson }}</pre>
                      </div>
                    </div>
                  </div>
                </template>
              </div>
            </div>
          </div>

        </article>

        <aside class="p-4">
          <h2 class="mb-2 text-base font-black tracking-tight">Preset Manager</h2>
          <p class="mb-4 text-xs text-slate-600 dark:text-slate-400">Presets are saved as JSON files in a synced local directory.</p>

          <div class="mb-3 rounded-lg border border-slate-200 bg-slate-50 p-3 text-xs text-slate-700 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-300">
            Directory: <strong>{{ directoryLabel }}</strong>
          </div>

          <div v-if="hasConnectedDirectory" class="mb-4 space-y-2">
            <button
              type="button"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
              :disabled="!canUseDirectoryApi"
              @click="connectPresetDirectory"
            >
              Change Directory
            </button>
            <button
              type="button"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
              @click="disconnectPresetDirectory"
            >
              Disconnect Directory
            </button>
          </div>

          <div v-else class="mb-4 flex gap-2">
            <button
              type="button"
              class="flex-1 rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
              :disabled="!canUseDirectoryApi"
              @click="connectPresetDirectory"
            >
              Connect Directory
            </button>
          </div>

          <span class="mb-1 block text-xs font-semibold">Presets Actions</span>
          <button
            type="button"
            class="mb-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
            :disabled="!selectedPreset"
            @click="renameSelectedPreset"
          >
            <i class="fas fa-pen-to-square fa-fw"></i>
            Rename Selected Preset
          </button>

          <button
            type="button"
            class="mb-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
            :disabled="!presetDirectoryHandle"
            @click="savePreset"
          >
            <i class="fas fa-copy fa-fw"></i>
            {{ selectedPreset ? 'Duplicate Current Preset' : 'Save Preset As' }}
          </button>

          <button
            type="button"
            class="mb-4 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold transition hover:border-slate-400 disabled:cursor-not-allowed dark:border-slate-700 dark:bg-slate-950 dark:hover:border-slate-500"
            :disabled="!presetDirectoryHandle"
            @click="createNewPreset"
          >
            <i class="fas fa-plus fa-fw"></i> Create New Preset
          </button>

          <label class="mb-2 block">
            <span class="mb-1 block text-xs font-semibold">Saved Presets</span>
            <select
              v-model="selectedPresetId"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
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
              class="flex-1 px-3 py-2 text-sm font-semibold transition btn-success"
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

          <div class="mt-4 border-t border-slate-200 pt-4 dark:border-slate-700">
            <h3 class="mb-3 text-sm font-semibold">Request Settings</h3>
            <div class="grid gap-3">
              <label>
                <span class="mb-1 block text-xs font-semibold">API Key</span>
                <input
                  v-model="settings.apiKey"
                  type="password"
                  placeholder="sk-or-v1-..."
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
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
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
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
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
                />
              </label>

              <label class="flex items-center justify-between gap-3">
                <span class="text-xs font-semibold">Reasoning</span>
                <span class="relative inline-flex cursor-pointer items-center">
                  <input v-model="settings.reasoningEnabled" type="checkbox" class="peer sr-only" />
                  <span
                    class="h-6 w-11 rounded-full bg-slate-300 transition peer-checked:bg-slate-900 peer-focus:outline-none peer-focus:ring-2 peer-focus:ring-slate-400 dark:bg-slate-700 dark:peer-checked:bg-slate-300 dark:peer-focus:ring-slate-500"
                  />
                  <span
                    class="pointer-events-none absolute left-0.5 top-0.5 h-5 w-5 rounded-full bg-white shadow transition peer-checked:translate-x-5 dark:bg-slate-950"
                  />
                </span>
              </label>

              <label>
                <span class="mb-1 block text-xs font-semibold">Reasoning Effort</span>
                <select
                  v-model="settings.reasoningEffort"
                  :disabled="!settings.reasoningEnabled"
                  class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm outline-none transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300"
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
