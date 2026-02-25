<script setup lang="ts">
import { Compartment, EditorState, Prec } from '@codemirror/state'
import { EditorView, keymap } from '@codemirror/view'
import { basicSetup } from 'codemirror'
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'

const props = withDefaults(
  defineProps<{
    modelValue: string,
    minHeight?: string,
    maxHeight?: string,
    ariaLabel?: string,
    dark?: boolean,
  }>(),
  {
    minHeight: "10vh",
    maxHeight: "30vh",
    ariaLabel: 'Editor',
    dark: false,
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: string]
  'mod-enter': []
}>()

const editorRoot = ref<HTMLElement | null>(null)
let editorView: EditorView | null = null
let syncingFromParent = false
const themeCompartment = new Compartment()

function editorTheme(isDark: boolean) {
  return EditorView.theme(
    {
      '&': {
        height: 'auto',
        ...(isDark
          ? {
              backgroundColor: '#0b1220',
              color: '#e2e8f0',
            }
          : {
              backgroundColor: '#ffffff',
              color: '#0f172a',
            }),
      },
      '.cm-content': {
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
        fontSize: '0.875rem',
        padding: '0.75rem',
      },
      '.cm-content, .cm-gutter': {
        minHeight: props.minHeight,
      },
      '.cm-scroller': {
        overflow: 'auto',
        maxHeight: props.maxHeight,
      },
      '&.cm-focused': {
        outline: 'none',
      },
      '.cm-gutters': isDark
        ? {
            backgroundColor: '#0f172a',
            color: '#94a3b8',
            border: 'none',
          }
        : {
            backgroundColor: '#f8fafc',
            color: '#64748b',
            border: 'none',
          },
      '.cm-activeLine': isDark ? { backgroundColor: '#1e293b' } : { backgroundColor: '#f1f5f9' },
      '.cm-activeLineGutter': isDark ? { backgroundColor: '#1e293b' } : { backgroundColor: '#f1f5f9' },
      '.cm-selectionBackground, ::selection': isDark
        ? { backgroundColor: '#334155 !important' }
        : { backgroundColor: '#cbd5e1 !important' },
      '.cm-cursor, .cm-dropCursor': isDark ? { borderLeftColor: '#e2e8f0' } : { borderLeftColor: '#0f172a' },
    },
    { dark: isDark },
  )
}

onMounted(() => {
  if (!editorRoot.value) {
    return
  }

  const state = EditorState.create({
    doc: props.modelValue,
    extensions: [
      Prec.highest(
        keymap.of([
          {
            key: 'Mod-Enter',
            run: () => {
              emit('mod-enter')
              return true
            },
          },
        ]),
      ),
      basicSetup,
      EditorView.lineWrapping,
      themeCompartment.of(editorTheme(props.dark)),
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

watch(
  () => props.dark,
  (isDark) => {
    if (!editorView) {
      return
    }
    editorView.dispatch({
      effects: themeCompartment.reconfigure(editorTheme(isDark)),
    })
  },
)

onBeforeUnmount(() => {
  editorView?.destroy()
  editorView = null
})
</script>

<template>
  <div class="code-editor-shell" :class="{ 'code-editor-shell-dark': dark }">
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

.code-editor-shell-dark {
  border-color: #334155;
  background: #0b1220;
}

.code-editor-shell-dark:focus-within {
  border-color: #cbd5e1;
}

.code-editor-root {
  width: 100%;
}
</style>
