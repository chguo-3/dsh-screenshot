/**
 * dsh-screenshot — Client half.
 *
 * 输入框工具行里多一个截图按钮：点一下就进入系统级的全屏截图编辑器
 * （框选 / 调选区 / 涂鸦都在原生窗口里完成），
 * 完成后把裁好并烧入笔迹的 PNG 直接塞进当前草稿，像微信/QQ 一样。
 *
 * 右键按钮（或点旁边的箭头）可以切换「截图时隐藏 DSH 窗口」。
 */

window.__ModuleLoader__.load({
  id: 'dsh-screenshot',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    const API = '/dsh-screenshot'
    const NAMESPACE = 'screenshot'
    const PREF_KEY = 'dsh-screenshot.hide-window'

    /* ------------------------------------------------------------- 文案 */

    const DICT = {
      zh: {
        button: '截图',
        buttonHint: '截图（在屏幕上框选、涂鸦后放进输入框）',
        menuHide: '截图时隐藏 DSH 窗口',
        menuHint: '隐藏后截到的是桌面，不会把自己截进去',
        capturing: '正在准备截图…',
        attaching: '正在放进输入框…',
        busy: '当前会话正在发送消息，稍后再试',
        failed: '截图失败',
        cancelled: '已取消截图',
      },
      en: {
        button: 'Screenshot',
        buttonHint: 'Screenshot (select and annotate on screen)',
        menuHide: 'Hide DSH window while capturing',
        menuHint: 'Capture the desktop without this window in it',
        capturing: 'Preparing screenshot…',
        attaching: 'Adding to the composer…',
        busy: 'This session is sending a message; try again in a moment',
        failed: 'Screenshot failed',
        cancelled: 'Screenshot cancelled',
      },
    }

    let translateCache = null

    function localTranslate(locale) {
      const dict = DICT[locale] ?? DICT.zh
      return (key) => dict[key] ?? DICT.zh[key] ?? key
    }

    /** 用 Client 的 locale 服务注册文案；服务缺失时退回本地字典。 */
    function makeTranslate(ctx) {
      if (translateCache) return translateCache
      const locale = ctx.get('locale')
      let t = localTranslate('zh')
      if (locale && typeof locale.register === 'function' && typeof locale.bind === 'function') {
        const active = typeof locale.getLocale === 'function' ? locale.getLocale()?.active : 'zh'
        const localeId = DICT[active] ? active : 'zh'
        try {
          ctx.effect(() => locale.register(NAMESPACE, localeId, DICT[localeId]), 'dsh-screenshot: locale')
          t = locale.bind(NAMESPACE)
        } catch {
          t = localTranslate(localeId)
        }
      }
      translateCache = t
      return t
    }

    /* ------------------------------------------------------------- 状态 */

    function createStore(initial) {
      let state = initial
      const listeners = new Set()
      return {
        get: () => state,
        set(next) {
          state = { ...state, ...next }
          for (const listener of listeners) listener()
        },
        subscribe(listener) {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
      }
    }

    const toastStore = createStore({ message: '', at: 0 })

    function useStore(store) {
      if (typeof React.useSyncExternalStore === 'function') {
        return React.useSyncExternalStore(store.subscribe, store.get, store.get)
      }
      const [state, setState] = React.useState(store.get)
      React.useEffect(() => store.subscribe(() => setState(store.get())), [store])
      return state
    }

    function readHidePref() {
      try {
        return window.localStorage.getItem(PREF_KEY) === '1'
      } catch {
        return false
      }
    }

    function writeHidePref(value) {
      try {
        window.localStorage.setItem(PREF_KEY, value ? '1' : '0')
      } catch {
        /* 存不了就算了，只影响本次会话 */
      }
    }

    /* ------------------------------------------------------------- 截图 */

    function timestamp() {
      const now = new Date()
      const pad = (value) => String(value).padStart(2, '0')
      return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
    }

    async function captureIntoComposer(composer, options) {
      const { ctx, sessionId, inputActions } = composer
      const t = makeTranslate(ctx)
      const { hide } = options

      toastStore.set({ message: '', at: 0 })
      try {
        const response = await fetch(`${API}/capture${hide ? '?hide=1' : ''}`, { cache: 'no-store' })
        if (response.status === 409) return
        if (!response.ok) {
          let detail = `HTTP ${response.status}`
          try {
            const body = await response.json()
            if (body?.error) detail = String(body.error)
          } catch {}
          throw new Error(detail)
        }
        const blob = await response.blob()
        const file = new File([blob], `screenshot-${timestamp()}.png`, { type: 'image/png' })
        const conversation = ctx.get('conversation')
        if (!conversation || typeof conversation.createDrafts !== 'function') {
          throw new Error('composer is unavailable')
        }
        const drafts = conversation.createDrafts(sessionId, [file])
        const ids = (drafts ?? []).map((draft) => draft.id).filter(Boolean)
        if (ids.length === 0) throw new Error('composer rejected the image')
        const accepted = typeof inputActions?.addAttachments === 'function' ? inputActions.addAttachments(ids) : false
        if (accepted === false) {
          if (typeof conversation.releaseDraftAttachments === 'function') {
            conversation.releaseDraftAttachments(drafts)
          }
          throw new Error(t('busy'))
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        toastStore.set({ message: `${t('failed')}：${message}`, at: Date.now() })
      }
    }

    /* ------------------------------------------------------------- 组件 */

    function CameraIcon() {
      return h(
        'svg',
        { width: 16, height: 16, viewBox: '0 0 24 24', fill: 'none', 'aria-hidden': 'true' },
        h('path', {
          d: 'M3.5 8.5A2.5 2.5 0 0 1 6 6h1.2c.5 0 .9-.2 1.2-.6l.7-.9c.3-.4.7-.6 1.2-.6h3.4c.5 0 .9.2 1.2.6l.7.9c.3.4.7.6 1.2.6H18a2.5 2.5 0 0 1 2.5 2.5v9A2.5 2.5 0 0 1 18 20H6a2.5 2.5 0 0 1-2.5-2.5v-9Z',
          stroke: 'currentColor',
          strokeWidth: 1.6,
          strokeLinejoin: 'round',
        }),
        h('circle', { cx: 12, cy: 13, r: 3.4, stroke: 'currentColor', strokeWidth: 1.6 }),
      )
    }

    function ChevronIcon() {
      return h(
        'svg',
        { width: 10, height: 10, viewBox: '0 0 24 24', fill: 'none', 'aria-hidden': 'true' },
        h('path', {
          d: 'M6 9l6 6 6-6',
          stroke: 'currentColor',
          strokeWidth: 2.2,
          strokeLinecap: 'round',
          strokeLinejoin: 'round',
        }),
      )
    }

    function Spinner() {
      return h('span', { className: 'dsh-shot-spinner', 'aria-hidden': 'true' })
    }

    function ShotMenu({ t, hide, onToggle, onClose }) {
      const ref = React.useRef(null)
      React.useEffect(() => {
        const onPointerDown = (event) => {
          if (ref.current && !ref.current.contains(event.target)) onClose()
        }
        const onKeyDown = (event) => {
          if (event.key === 'Escape') onClose()
        }
        document.addEventListener('pointerdown', onPointerDown, true)
        document.addEventListener('keydown', onKeyDown, true)
        return () => {
          document.removeEventListener('pointerdown', onPointerDown, true)
          document.removeEventListener('keydown', onKeyDown, true)
        }
      }, [onClose])
      return h(
        'div',
        { className: 'dsh-shot-menu', ref, role: 'menu' },
        h(
          'button',
          {
            type: 'button',
            className: 'dsh-shot-menu-item',
            role: 'menuitemcheckbox',
            'aria-checked': hide,
            onClick: onToggle,
          },
          h('span', { className: `dsh-shot-check${hide ? ' is-on' : ''}`, 'aria-hidden': 'true' }, hide ? '✓' : ''),
          h('span', { className: 'dsh-shot-menu-label' }, t('menuHide')),
        ),
        h('div', { className: 'dsh-shot-menu-hint' }, t('menuHint')),
      )
    }

    function ShotButton(props) {
      const t = makeTranslate(props.ctx)
      const composerRef = React.useRef(null)
      const [busy, setBusy] = React.useState(false)
      const [menu, setMenu] = React.useState(false)
      const [hide, setHide] = React.useState(() => readHidePref())

      composerRef.current = { ctx: props.ctx, sessionId: props.sessionId, inputActions: props.inputActions }

      const start = React.useCallback(async () => {
        if (busy) return
        const composer = composerRef.current
        if (!composer || !composer.sessionId) return
        setBusy(true)
        setMenu(false)
        try {
          await captureIntoComposer(composer, { hide: readHidePref() })
        } finally {
          setBusy(false)
        }
      }, [busy])

      const toggleHide = React.useCallback(() => {
        setHide((current) => {
          const next = !current
          writeHidePref(next)
          return next
        })
      }, [])

      return h(
        'div',
        { className: 'dsh-shot-root' },
        h(
          'div',
          { className: `dsh-shot-group${busy ? ' is-busy' : ''}` },
          h(
            'button',
            {
              type: 'button',
              className: 'dsh-shot-button',
              title: t('buttonHint'),
              'aria-label': t('button'),
              disabled: busy,
              onClick: start,
            },
            h('span', { className: 'dsh-shot-icon' }, busy ? h(Spinner) : h(CameraIcon)),
          ),
          h(
            'button',
            {
              type: 'button',
              className: 'dsh-shot-caret',
              title: t('menuHide'),
              'aria-haspopup': 'menu',
              'aria-expanded': menu,
              onClick: () => setMenu((open) => !open),
            },
            h(ChevronIcon),
          ),
        ),
        menu ? h(ShotMenu, { t, hide, onToggle: toggleHide, onClose: () => setMenu(false) }) : null,
      )
    }

    function ShotToast() {
      const state = useStore(toastStore)
      const [hidden, setHidden] = React.useState(true)
      const at = state.at
      const message = state.message

      React.useEffect(() => {
        if (!message) {
          setHidden(true)
          return
        }
        setHidden(false)
        const timer = setTimeout(() => setHidden(true), 6000)
        return () => clearTimeout(timer)
      }, [message, at])

      if (hidden || !message) return null
      return h(
        'div',
        { className: 'dsh-shot-toast', role: 'status' },
        h('span', { className: 'dsh-shot-toast-text' }, message),
      )
    }

    /* ------------------------------------------------------------- 样式 */

    const CSS = `
.dsh-shot-root {
  position: relative;
  display: flex;
  align-items: center;
}
.dsh-shot-group {
  display: inline-flex;
  align-items: stretch;
  border-radius: 999px;
  border: 1px solid var(--dsw-alias-border-l2);
  background: var(--dsw-alias-bg-layer-1);
  overflow: hidden;
}
.dsh-shot-group.is-busy { opacity: 0.7; }
.dsh-shot-button,
.dsh-shot-caret {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 0;
  background: transparent;
  color: var(--dsw-alias-label-secondary);
  cursor: pointer;
  padding: 0;
}
.dsh-shot-button { width: 30px; height: 28px; }
.dsh-shot-caret { width: 18px; height: 28px; border-left: 1px solid var(--dsw-alias-border-l1); }
.dsh-shot-button:hover,
.dsh-shot-caret:hover { background: var(--dsw-alias-bg-layer-2); color: var(--dsw-alias-label-primary); }
.dsh-shot-button:disabled { cursor: default; }
.dsh-shot-icon { display: inline-flex; }
.dsh-shot-spinner {
  width: 14px;
  height: 14px;
  border-radius: 999px;
  border: 2px solid var(--dsw-alias-border-l2);
  border-top-color: var(--dsw-alias-brand-primary);
  animation: dsh-shot-spin 0.7s linear infinite;
}
@keyframes dsh-shot-spin { to { transform: rotate(360deg); } }
.dsh-shot-menu {
  position: absolute;
  left: 0;
  bottom: calc(100% + 8px);
  z-index: 2147482000;
  min-width: 232px;
  padding: 8px;
  border-radius: 12px;
  border: 1px solid var(--dsw-alias-border-l2);
  background: var(--dsw-alias-bg-layer-1);
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.18);
}
.dsh-shot-menu-item {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 7px 8px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: var(--dsw-alias-label-primary);
  font-size: 13px;
  text-align: left;
  cursor: pointer;
}
.dsh-shot-menu-item:hover { background: var(--dsw-alias-bg-layer-2); }
.dsh-shot-check {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 16px;
  height: 16px;
  border-radius: 4px;
  border: 1px solid var(--dsw-alias-border-l2);
  font-size: 11px;
  line-height: 1;
  color: #fff;
}
.dsh-shot-check.is-on { background: var(--dsw-alias-brand-primary); border-color: var(--dsw-alias-brand-primary); }
.dsh-shot-menu-label { flex: 1 1 auto; }
.dsh-shot-menu-hint {
  padding: 2px 8px 4px 32px;
  font-size: 11px;
  line-height: 1.5;
  color: var(--dsw-alias-label-secondary);
}
.dsh-shot-toast {
  position: fixed;
  left: 50%;
  bottom: 96px;
  transform: translateX(-50%);
  z-index: 2147483000;
  max-width: min(520px, calc(100vw - 48px));
  padding: 9px 14px;
  border-radius: 10px;
  border: 1px solid var(--dsw-alias-state-error-primary);
  background: var(--dsw-alias-bg-overlay);
  color: var(--dsw-alias-label-primary);
  font-size: 13px;
  line-height: 1.5;
  box-shadow: 0 10px 28px rgba(0, 0, 0, 0.2);
  pointer-events: none;
}
`

    /* ------------------------------------------------------------- 装配 */

    function apply(ctx) {
      const style = document.createElement('style')
      style.dataset.dshScreenshot = ''
      style.textContent = CSS
      document.head.appendChild(style)
      ctx.effect(() => () => style.remove(), 'dsh-screenshot: style')

      makeTranslate(ctx)

      const slots = ctx.get('slots')
      if (!slots || typeof slots.inject !== 'function') return

      slots.inject('conversation.input.left', () =>
        slots.register({ name: 'conversation.input.left', id: 'screenshot', order: 6, label: '截图' }, (props) =>
          h(ShotButton, { ...props, ctx }),
        ),
      )

      slots.inject('shell.overlay', () =>
        slots.register({ name: 'shell.overlay', id: 'screenshot-toast', order: 40, label: '截图提示' }, ShotToast),
      )
    }

    return { inject: ['slots', 'locale'], apply }
  },
})

