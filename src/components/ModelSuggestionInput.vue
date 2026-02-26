<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'

interface ModelSuggestion {
  id: string
  name: string
}

const props = withDefaults(
  defineProps<{
    modelValue: string
    suggestions: ModelSuggestion[]
    loading?: boolean
    error?: string
    placeholder?: string
    disabled?: boolean
  }>(),
  {
    loading: false,
    error: '',
    placeholder: '',
    disabled: false,
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: string]
}>()

const isInputFocused = ref(false)
const activeSuggestionIndex = ref(-1)
const suggestionListRef = ref<HTMLElement | null>(null)

const filteredSuggestions = computed(() => {
  const query = props.modelValue.trim().toLowerCase()
  if (!query) {
    return props.suggestions.slice(0, 12)
  }

  return props.suggestions
    .filter((entry) => entry.id.toLowerCase().includes(query) || entry.name.toLowerCase().includes(query))
    .slice(0, 12)
})

const showSuggestions = computed(() => !props.disabled && isInputFocused.value && filteredSuggestions.value.length > 0)

function updateValue(event: Event) {
  const target = event.target as HTMLInputElement
  emit('update:modelValue', target.value)
}

function applySuggestion(value: string) {
  emit('update:modelValue', value)
  activeSuggestionIndex.value = -1
  isInputFocused.value = false
}

function ensureActiveSuggestionVisible() {
  nextTick(() => {
    if (activeSuggestionIndex.value < 0) {
      return
    }

    const list = suggestionListRef.value
    if (!list) {
      return
    }

    const activeElement = list.querySelector<HTMLElement>(`[data-suggestion-index="${activeSuggestionIndex.value}"]`)
    activeElement?.scrollIntoView({ block: 'nearest' })
  })
}

function handleInputKeydown(event: KeyboardEvent) {
  if (props.disabled) {
    return
  }

  if (event.key === 'ArrowDown' && !showSuggestions.value && filteredSuggestions.value.length > 0) {
    event.preventDefault()
    isInputFocused.value = true
    activeSuggestionIndex.value = 0
    ensureActiveSuggestionVisible()
    return
  }

  if (!showSuggestions.value) {
    return
  }

  const maxIndex = filteredSuggestions.value.length - 1
  if (maxIndex < 0) {
    return
  }

  if (event.key === 'ArrowDown') {
    event.preventDefault()
    activeSuggestionIndex.value = activeSuggestionIndex.value >= maxIndex ? 0 : activeSuggestionIndex.value + 1
    ensureActiveSuggestionVisible()
    return
  }

  if (event.key === 'ArrowUp') {
    event.preventDefault()
    activeSuggestionIndex.value = activeSuggestionIndex.value <= 0 ? maxIndex : activeSuggestionIndex.value - 1
    ensureActiveSuggestionVisible()
    return
  }

  if (event.key === 'Enter' && activeSuggestionIndex.value >= 0) {
    event.preventDefault()
    const selectedSuggestion = filteredSuggestions.value[activeSuggestionIndex.value]
    if (selectedSuggestion) {
      applySuggestion(selectedSuggestion.id)
    }
    return
  }

  if (event.key === 'Escape') {
    event.preventDefault()
    activeSuggestionIndex.value = -1
    isInputFocused.value = false
  }
}

watch(filteredSuggestions, (suggestions) => {
  if (suggestions.length === 0) {
    activeSuggestionIndex.value = -1
    return
  }

  if (activeSuggestionIndex.value > suggestions.length - 1) {
    activeSuggestionIndex.value = suggestions.length - 1
  }
})

watch(
  () => props.disabled,
  (disabled) => {
    if (disabled) {
      isInputFocused.value = false
      activeSuggestionIndex.value = -1
    }
  },
)
</script>

<template>
  <div class="relative">
    <input
      :value="modelValue"
      type="text"
      :placeholder="placeholder"
      :disabled="disabled"
      class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 outline-none ring-0 transition focus:border-slate-900 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-100 dark:focus:border-slate-300 disabled:opacity-30"
      @input="updateValue"
      @focus="isInputFocused = true"
      @blur="isInputFocused = false; activeSuggestionIndex = -1"
      @keydown="handleInputKeydown"
    />
    <div
      v-if="showSuggestions"
      ref="suggestionListRef"
      class="absolute z-20 mt-1 max-h-64 w-full overflow-auto rounded-xl border border-slate-200 bg-white p-1 shadow-lg dark:border-slate-700 dark:bg-slate-900"
    >
      <button
        v-for="(entry, index) in filteredSuggestions"
        :key="entry.id"
        type="button"
        :data-suggestion-index="index"
        class="block w-full rounded-lg px-3 py-2 text-left text-sm transition hover:bg-slate-100 dark:hover:bg-slate-800"
        :class="{ 'bg-slate-100 dark:bg-slate-800': index === activeSuggestionIndex }"
        @mouseenter="activeSuggestionIndex = index"
        @mousedown.prevent="applySuggestion(entry.id)"
      >
        <div class="font-semibold text-slate-900 dark:text-slate-100">{{ entry.id }}</div>
        <div v-if="entry.name && entry.name !== entry.id" class="text-xs text-slate-500 dark:text-slate-400">{{ entry.name }}</div>
      </button>
    </div>
  </div>
  <span v-if="loading" class="mt-1 block text-xs text-slate-500 dark:text-slate-400">Loading model suggestions...</span>
  <span v-else-if="error" class="mt-1 block text-xs text-rose-600">{{ error }}</span>
</template>
