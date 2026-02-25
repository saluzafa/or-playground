<script setup lang="ts">
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { basicSetup } from 'codemirror'
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    modelValue: string,
    minHeight?: string,
    maxHeight?: string,
    ariaLabel?: string,
  }>(),
  {
    minHeight: "10vh",
    maxHeight: "20vh",
    ariaLabel: 'Editor',
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: string]
}>()

const editorRoot = ref<HTMLElement | null>(null)
let editorView: EditorView | null = null
let syncingFromParent = false

onMounted(() => {
  if (!editorRoot.value) {
    return
  }

  const state = EditorState.create({
    doc: props.modelValue,
    extensions: [
      basicSetup,
      EditorView.lineWrapping,
      EditorView.theme({
        '&': {
          height: '100%',
        },
        '.cm-content': {
          fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
          fontSize: '0.875rem',
          padding: '0.75rem',
          minHeight: props.minHeight,
          maxHeight: props.maxHeight,
        },
        '.cm-scroller': {
          overflow: 'auto',
        },
        '&.cm-focused': {
          outline: 'none',
        },
      }),
      EditorView.contentAttributes.of({
        'aria-label': props.ariaLabel,
      }),
      EditorView.updateListener.of((update) => {
        if (!update.docChanged || syncingFromParent) {
          return
        }
        emit('update:modelValue', update.state.doc.toString())
      }),
    ],
  })

  editorView = new EditorView({
    state,
    parent: editorRoot.value,
  })
})

watch(
  () => props.modelValue,
  (nextValue) => {
    if (!editorView) {
      return
    }
    const currentValue = editorView.state.doc.toString()
    if (nextValue === currentValue) {
      return
    }

    syncingFromParent = true
    editorView.dispatch({
      changes: { from: 0, to: currentValue.length, insert: nextValue },
    })
    syncingFromParent = false
  },
)

onBeforeUnmount(() => {
  editorView?.destroy()
  editorView = null
})
</script>

<template>
  <div class="code-editor-shell">
    <div ref="editorRoot" class="code-editor-root" />
  </div>
</template>

<style scoped>
.code-editor-shell {
  width: 100%;
  border: 1px solid #cbd5e1;
  border-radius: 0.75rem;
  overflow: hidden;
  background: #fff;
  transition: border-color 150ms ease;
}

.code-editor-shell:focus-within {
  border-color: #0f172a;
}

.code-editor-root {
  width: 100%;
}
</style>
