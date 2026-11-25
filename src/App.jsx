import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'

const GITHUB_URL = 'https://github.com/wuxiao/RimeAI'
const THEME_STORAGE_KEY = 'rimeai-theme'

const METRIC_QUALIFIER = '974 样本冻结集 · Release 暂未打包 MLX'

const ArrowRight = ({ size = 18 }) => (
  <svg
    aria-hidden="true"
    className="icon"
    fill="none"
    height={size}
    viewBox="0 0 24 24"
    width={size}
  >
    <path d="M5 12h13M14 7l5 5-5 5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
  </svg>
)

const Spark = ({ size = 20 }) => (
  <svg
    aria-hidden="true"
    className="icon"
    fill="none"
    height={size}
    viewBox="0 0 24 24"
    width={size}
  >
    <path d="M12 2.7c.45 4.55 2.75 6.85 7.3 7.3-4.55.45-6.85 2.75-7.3 7.3-.45-4.55-2.75-6.85-7.3-7.3 4.55-.45 6.85-2.75 7.3-7.3Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.6" />
    <path d="M19 16.3c.18 1.8 1.08 2.7 2.9 2.9-1.82.18-2.72 1.08-2.9 2.9-.18-1.82-1.08-2.72-2.9-2.9 1.82-.2 2.72-1.1 2.9-2.9Z" fill="currentColor" />
  </svg>
)

const Check = ({ size = 18 }) => (
  <svg
    aria-hidden="true"
    className="icon"
    fill="none"
    height={size}
    viewBox="0 0 24 24"
    width={size}
  >
    <path d="m5 12 4.4 4.5L19 7" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
  </svg>
)

const ResetIcon = () => (
  <svg aria-hidden="true" fill="none" viewBox="0 0 24 24">
    <path d="M19 8V4m0 0h-4m4 0-3 3a7 7 0 1 0 1.5 7.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
  </svg>
)

const Spinner = () => (
  <svg aria-hidden="true" className="icon spin" fill="none" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="8.5" stroke="currentColor" strokeOpacity=".28" strokeWidth="2" />
    <path d="M20.5 12a8.5 8.5 0 0 0-8.5-8.5" stroke="currentColor" strokeLinecap="round" strokeWidth="2" />
  </svg>
)

const SystemIcon = ({ size = 16 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <rect x="3.5" y="5" width="17" height="11.5" rx="2" stroke="currentColor" strokeWidth="1.7" />
    <path d="M9 20h6M12 16.5V20" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
  </svg>
)

const SunIcon = ({ size = 16 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.7" />
    <path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M18.4 5.6l-1.6 1.6M7.2 16.8l-1.6 1.6" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
  </svg>
)

const MoonIcon = ({ size = 16 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M20 14.6A8.2 8.2 0 1 1 9.4 4a6.6 6.6 0 0 0 10.6 10.6Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.7" />
  </svg>
)

const LockIcon = ({ size = 14 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <rect x="5.5" y="10.5" width="13" height="9.5" rx="2" stroke="currentColor" strokeWidth="1.7" />
    <path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
  </svg>
)

const LaptopIcon = () => (
  <svg aria-hidden="true" fill="none" viewBox="0 0 24 24">
    <path d="M5 6.5h14v10H5zM3 19h18" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
  </svg>
)

const BrandMark = ({ size = 34 }) => (
  <svg
    aria-hidden="true"
    className="brand-mark"
    fill="none"
    height={size}
    viewBox="0 0 40 40"
    width={size}
  >
    <path d="M8 33V7h13c7 0 11 3.8 11 10s-4.2 10-11 10H12" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="4.4" />
    <path d="m21 27 11 8M8 7l7 7" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="4.4" />
  </svg>
)

const Kbd = ({ children }) => <kbd className="kbd">{children}</kbd>

/** Renders a plain string or an array of `{ t: text }` / `{ k: keycap }` tokens. */
function Rich({ parts }) {
  if (typeof parts === 'string') {
    return parts
  }
  return parts.map((part, index) =>
    part.k ? <Kbd key={index}>{part.k}</Kbd> : <Fragment key={index}>{part.t}</Fragment>,
  )
}

const MetricQualifier = () => <small className="metric-qualifier">{METRIC_QUALIFIER}</small>

const ContextIcon = ({ type }) => {
  if (type === 'strict') {
    return (
      <svg aria-hidden="true" fill="none" viewBox="0 0 28 28">
        <path d="M3 14h3l2-8 4 16 4-16 3 12 2-4h4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
      </svg>
    )
  }

  if (type === 'standard') {
    return (
      <svg aria-hidden="true" fill="none" viewBox="0 0 28 28">
        <path d="M5 7h18M5 14h13M5 21h9" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
      </svg>
    )
  }

  return (
    <svg aria-hidden="true" fill="none" viewBox="0 0 28 28">
      <path d="M9.5 22.5v-4.2a5 5 0 0 1-2.8-4.5c0-2.8 2.2-5 5-5 .8-2.3 3-4 5.7-4 3.2 0 5.8 2.5 5.8 5.7 0 1.8-.8 3.3-2 4.4a4.6 4.6 0 0 1-4.5 5.4h-1v2.2M12.8 8.8v13.7M9.5 12.5h3.3M15.7 10.7v9.6M15.7 14.5h4.8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.45" />
    </svg>
  )
}

const ProcessIcon = ({ step }) => {
  if (step === '01') {
    return (
      <svg aria-hidden="true" fill="none" viewBox="0 0 40 40">
        <circle cx="20" cy="20" r="16" stroke="currentColor" strokeOpacity=".36" />
        <circle cx="20" cy="20" r="11" stroke="currentColor" strokeOpacity=".58" />
        <path d="m22 9-8 12h6l-2 10 8-13h-6l2-9Z" fill="currentColor" />
      </svg>
    )
  }

  if (step === '02') {
    return (
      <svg aria-hidden="true" fill="none" viewBox="0 0 40 40">
        <circle cx="20" cy="20" r="16" stroke="currentColor" strokeOpacity=".36" />
        <path d="M16 29v-5.2a6 6 0 0 1-3-5.2 6 6 0 0 1 6-6c1-2.5 3.2-4 6-4a7 7 0 0 1 4.2 12.6 5.3 5.3 0 0 1-5.2 6.2h-1V30M20 12.6V30m-4-13.5h4m3-3.5v14.4m0-8.4h6" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.4" />
      </svg>
    )
  }

  return (
    <svg aria-hidden="true" fill="none" viewBox="0 0 40 40">
      <circle cx="20" cy="20" r="16" stroke="currentColor" strokeOpacity=".36" />
      <path d="M20 9.5c.55 5.2 3.25 7.9 8.5 8.5-5.25.55-7.95 3.25-8.5 8.5-.55-5.25-3.25-7.95-8.5-8.5 5.25-.6 7.95-3.3 8.5-8.5Z" fill="currentColor" />
    </svg>
  )
}

const CommitmentIcon = ({ type }) => {
  if (type === 'secure') {
    return (
      <span className="commitment-icon" aria-hidden="true">
        <svg fill="none" viewBox="0 0 32 32">
          <circle cx="16" cy="16" r="6.5" stroke="currentColor" strokeDasharray="2.4 2.4" strokeWidth="1.5" />
          <path d="M16 5v4M16 23v4M5 16h4M23 16h4M8.2 8.2l2.8 2.8M21 21l2.8 2.8M23.8 8.2 21 11M11 21l-2.8 2.8" stroke="currentColor" strokeLinecap="round" strokeWidth="1.5" />
          <path d="m13 16 2 2 4-4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
        </svg>
      </span>
    )
  }

  if (type === 'isolation') {
    return (
      <span className="commitment-icon" aria-hidden="true">
        <svg fill="none" viewBox="0 0 32 32">
          <path d="m16 6 10 5-10 5L6 11l10-5Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.5" />
          <path d="m7 16 9 4.5 9-4.5M7 21l9 4.5 9-4.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
        </svg>
      </span>
    )
  }

  return (
    <span className="commitment-icon" aria-hidden="true">
      <svg fill="none" viewBox="0 0 32 32">
        <path d="M8 10h16M13 10V7h6v3M11 13l1 13h8l1-13M14.5 15v8M17.5 15v8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
      </svg>
    </span>
  )
}

function prefersReducedMotion() {
  return typeof window !== 'undefined'
    && typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function scrollIntoView(target) {
  if (!target) {
    return
  }
  target.scrollIntoView({
    behavior: prefersReducedMotion() ? 'auto' : 'smooth',
    block: 'start',
  })
}

function scrollToSection(id) {
  scrollIntoView(document.getElementById(id))
}

/**
 * Arrow/Home/End key handling with a roving tabindex for tablists and
 * radiogroups. Focus follows the newly activated item after React re-renders.
 */
function useRovingFocus(ids, activeId, domId, onActivate) {
  const pendingFocus = useRef(null)

  useEffect(() => {
    if (pendingFocus.current === null || pendingFocus.current !== activeId) {
      return
    }
    pendingFocus.current = null
    const element = document.getElementById(domId(activeId))
    if (element) {
      element.focus()
      element.scrollIntoView({
        behavior: prefersReducedMotion() ? 'auto' : 'smooth',
        block: 'nearest',
        inline: 'nearest',
      })
    }
  }, [activeId, domId])

  return useCallback((event) => {
    const currentIndex = ids.indexOf(event.currentTarget.dataset.rovingId)
    if (currentIndex < 0) {
      return
    }
    let nextIndex = null
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
      nextIndex = (currentIndex + 1) % ids.length
    } else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') {
      nextIndex = (currentIndex - 1 + ids.length) % ids.length
    } else if (event.key === 'Home') {
      nextIndex = 0
    } else if (event.key === 'End') {
      nextIndex = ids.length - 1
    }
    if (nextIndex === null) {
      return
    }
    event.preventDefault()
    const nextId = ids[nextIndex]
    pendingFocus.current = nextId
    onActivate(nextId)
  }, [ids, onActivate])
}

const themes = [
  { id: 'system', label: '跟随系统', Icon: SystemIcon },
  { id: 'light', label: '浅色', Icon: SunIcon },
  { id: 'dark', label: '深色', Icon: MoonIcon },
]

function readStoredTheme() {
  try {
    const stored = window.localStorage.getItem(THEME_STORAGE_KEY)
    return stored === 'light' || stored === 'dark' ? stored : 'system'
  } catch {
    return 'system'
  }
}

function storeTheme(theme) {
  try {
    if (theme === 'system') {
      window.localStorage.removeItem(THEME_STORAGE_KEY)
    } else {
      window.localStorage.setItem(THEME_STORAGE_KEY, theme)
    }
  } catch {
    /* storage unavailable: the choice still applies for this visit */
  }
}

function ThemeSwitch() {
  const [theme, setTheme] = useState(readStoredTheme)
  const ids = useMemo(() => themes.map((item) => item.id), [])
  const selectTheme = useCallback((nextTheme) => {
    if (nextTheme === 'light' || nextTheme === 'dark') {
      document.documentElement.setAttribute('data-theme', nextTheme)
    } else {
      document.documentElement.removeAttribute('data-theme')
    }
    storeTheme(nextTheme)
    setTheme(nextTheme)
  }, [])
  const onKeyDown = useRovingFocus(ids, theme, (id) => `theme-${id}`, selectTheme)

  return (
    <div className="theme-switch">
      <div aria-label="颜色主题" className="theme-switch-options" onKeyDown={onKeyDown} role="radiogroup">
        {themes.map(({ id, label, Icon }) => {
          const isActive = theme === id
          return (
            <button
              aria-checked={isActive}
              className={isActive ? 'is-active' : ''}
              data-roving-id={id}
              id={`theme-${id}`}
              key={id}
              onClick={() => selectTheme(id)}
              role="radio"
              tabIndex={isActive ? 0 : -1}
              title={label}
              type="button"
            >
              <Icon />
              <span className="theme-switch-text">{label}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

function Header() {
  return (
    <header className="site-header">
      <a className="brand" href="#top" aria-label="RimeAI 首页">
        <BrandMark />
        <span>RimeAI</span>
      </a>

      <nav aria-label="主导航" className="main-nav">
        <a href="#how">工作方式</a>
        <span aria-hidden="true">/</span>
        <a href="#domain">产品能力</a>
        <span aria-hidden="true">/</span>
        <a href="#privacy">隐私</a>
        <span aria-hidden="true">/</span>
        <a href="#roadmap">发布路线</a>
      </nav>

      <div className="header-tools">
        <ThemeSwitch />
        <a className="header-action" href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
          <span>GitHub 源码</span>
          <ArrowRight />
        </a>
      </div>
    </header>
  )
}

/*
 * Hero demo: a genuine context-dependent ambiguity. Rime ranks 认识 first for
 * "xian dui jie ren shi" while the surrounding sentence calls for 人事. Both
 * key contracts are modelled on the real product: Space never waits for the
 * semantic arm, Tab only adopts a ready suggestion that differs from Rime's
 * first choice, and ←/→ move the focus between composition segments.
 */
const demoLead = {
  id: 'lead',
  pinyin: 'xia zhou ru zhi zhe jia gong si',
  draft: '下周入职这家公司',
  rime: ['下周入职这家公司'],
  ai: '下周入职这家公司',
}

const demoHR = {
  id: 'hr',
  pinyin: 'xian dui jie ren shi',
  draft: '先对接认识',
  rime: ['先对接认识', '先对接人事', '先对接人士'],
  ai: '先对接人事',
}

const DEMO_ANALYSIS_MS = 700
const DEMO_RESET_MS = 7000

/** Screen-reader announcement for the current demo state. */
function describeDemoState({ done, outcome, committedSentence, stage, selectable, focused }) {
  if (done) {
    return outcome === 'ai'
      ? `已采纳语义建议，上屏：${committedSentence}。`
      : `已提交 Rime 首选，上屏：${committedSentence}。`
  }
  if (stage === 'analyzing') {
    return '本地模型分析中。按 Space 可随时提交 Rime 首选，不必等待。'
  }
  if (selectable) {
    return `语义建议就绪：${focused.ai}。按 Tab 采纳；按 Space 仍提交 Rime 首选：${focused.rime[0]}。`
  }
  return `AI 建议与 Rime 首选一致：${focused.ai}，不可选。`
}

function describePreedit(focusId) {
  return focusId === demoLead.id
    ? `预编辑区：焦点段拼音 ${demoLead.pinyin}，逗号，后缀定稿 ${demoHR.draft}。`
    : `预编辑区：前缀定稿 ${demoLead.draft}，逗号，焦点段拼音 ${demoHR.pinyin}。`
}

/** Preedit line: the focused segment shows raw pinyin, the other shows its draft. */
function DemoComposition({ done, outcome, committedHR, focusId }) {
  if (done) {
    return (
      <p aria-hidden="true" className="composition">
        <span>{demoLead.draft}，</span>
        <strong className={`is-${outcome}`}>{committedHR}</strong>
      </p>
    )
  }
  return (
    <p aria-hidden="true" className="composition">
      {focusId === demoLead.id ? (
        <>
          <span className="segment is-focused"><span className="pinyin">{demoLead.pinyin}</span><span className="caret" /></span>
          <span className="literal">，</span>
          <span className="segment">{demoHR.draft}</span>
        </>
      ) : (
        <>
          <span className="segment">{demoLead.draft}</span>
          <span className="literal">，</span>
          <span className="segment is-focused"><span className="pinyin">{demoHR.pinyin}</span><span className="caret" /></span>
        </>
      )}
    </p>
  )
}

/** Rime candidate row + the independent semantic slot, or the commit outcome. */
function DemoPopover({ done, outcome, committedSentence, focused, stage, selectable, onAdopt }) {
  if (done) {
    return (
      <div className={`demo-outcome is-${outcome}`}>
        <span className="outcome-icon"><Check /></span>
        <span className="outcome-label">
          {outcome === 'ai' ? '已采纳语义建议' : '已提交 Rime 首选'}
        </span>
        <strong>{committedSentence}</strong>
      </div>
    )
  }

  const analyzing = stage === 'analyzing'
  return (
    <>
      <div className="candidate-row rime-row">
        <div className="candidate-items">
          {focused.rime.map((candidate, index) => (
            <span key={candidate}><b>{index + 1}</b> {candidate}</span>
          ))}
        </div>
        <em>Rime 稳定候选</em>
      </div>

      <button
        aria-busy={analyzing}
        aria-label={analyzing ? '本地模型分析中' : `语义建议：${focused.ai}`}
        className={`semantic-row is-${stage}${selectable ? ' is-selectable' : ''}`}
        disabled={!selectable}
        onClick={onAdopt}
        type="button"
      >
        <span className="semantic-main">
          {analyzing ? <Spinner /> : <Spark />}
          <span>{analyzing ? '本地模型分析中…' : focused.ai}</span>
        </span>
        <span className="semantic-action">
          {analyzing && '独立建议位 · 不阻塞输入'}
          {!analyzing && selectable && (
            <>
              <span className="semantic-primary"><Kbd>Tab</Kbd> 采纳</span>
              <span className="semantic-secondary"><Kbd>Space</Kbd> 仍提交 Rime 首选「{focused.rime[0]}」</span>
            </>
          )}
          {!analyzing && !selectable && '与 Rime 首选一致 · 不可选'}
        </span>
      </button>
    </>
  )
}

function EditorDemo() {
  const [session, setSession] = useState({ focusId: demoHR.id, stage: 'analyzing', outcome: null })
  const documentRef = useRef(null)

  const focused = session.focusId === demoLead.id ? demoLead : demoHR
  const done = session.stage === 'done'
  const selectable = session.stage === 'ready' && focused.ai !== focused.rime[0]
  const committedHR = session.outcome === 'ai' ? demoHR.ai : demoHR.draft
  const committedSentence = `${demoLead.draft}，${committedHR}`

  const reset = useCallback(() => {
    setSession({ focusId: demoHR.id, stage: 'analyzing', outcome: null })
  }, [])

  const moveFocus = useCallback((segmentId) => {
    setSession({ focusId: segmentId, stage: 'analyzing', outcome: null })
  }, [])

  const commit = useCallback((outcome) => {
    setSession((current) => (
      current.stage === 'done' ? current : { ...current, stage: 'done', outcome }
    ))
  }, [])

  useEffect(() => {
    if (session.stage !== 'analyzing') {
      return undefined
    }
    const timer = window.setTimeout(() => {
      setSession((current) => (
        current.stage === 'analyzing' ? { ...current, stage: 'ready' } : current
      ))
    }, DEMO_ANALYSIS_MS)
    return () => window.clearTimeout(timer)
  }, [session])

  useEffect(() => {
    if (session.stage !== 'done') {
      return undefined
    }
    const timer = window.setTimeout(() => {
      if (document.activeElement !== documentRef.current) {
        reset()
      }
    }, DEMO_RESET_MS)
    return () => window.clearTimeout(timer)
  }, [session, reset])

  const handleKeyDown = (event) => {
    if (event.target !== event.currentTarget) {
      return
    }
    if (session.stage === 'done') {
      if (event.key === 'Escape' || event.key === 'Enter') {
        event.preventDefault()
        reset()
      }
      return
    }
    switch (event.key) {
      case ' ':
        event.preventDefault()
        commit('rime')
        break
      case 'ArrowLeft':
        if (session.focusId === demoHR.id) {
          event.preventDefault()
          moveFocus(demoLead.id)
        }
        break
      case 'ArrowRight':
        if (session.focusId === demoLead.id) {
          event.preventDefault()
          moveFocus(demoHR.id)
        }
        break
      case 'Escape':
        event.preventDefault()
        reset()
        break
      case 'Tab':
        // Only consumed when it performs the adoption, so keyboard users are
        // never trapped inside the demo.
        if (!event.shiftKey && selectable) {
          event.preventDefault()
          commit('ai')
        }
        break
      default:
        break
    }
  }

  const announcement = describeDemoState({ done, outcome: session.outcome, committedSentence, stage: session.stage, selectable, focused })
  const preeditText = describePreedit(session.focusId)

  return (
    <div className="editor-shell">
      <div className="editor-titlebar">
        <div className="traffic-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div className="editor-title">入职准备.md <span>— 已编辑</span></div>
        <button aria-label="重新演示" className="reset-demo" onClick={reset} type="button">
          <ResetIcon />
        </button>
      </div>

      <div className="editor-toolbar" aria-hidden="true">
        <span>正文</span>
        <span>苹方</span>
        <span>16</span>
        <b>B</b>
        <i>I</i>
        <u>U</u>
        <span className="toolbar-lines">≡</span>
      </div>

      <div
        aria-describedby="demo-key-hints"
        aria-label="输入演示：聚焦后可用键盘操作"
        className={`editor-document${done ? ' is-committed' : ''}`}
        onKeyDown={handleKeyDown}
        ref={documentRef}
        role="group"
        tabIndex={0}
      >
        <p className="editor-doc-title">下周入职准备</p>
        <p>入职材料已经交给 HR 确认，工位与账号预计周一上午到位。</p>
        <p>为了尽快展开工作，第一周先约相关同事过一遍项目背景。</p>
        <p className="editor-lead">具体安排如下：</p>

        <DemoComposition committedHR={committedHR} done={done} focusId={session.focusId} outcome={session.outcome} />
        <span className="sr-only">{done ? `已上屏：${committedSentence}` : preeditText}</span>

        <div className="candidate-popover">
          <DemoPopover
            committedSentence={committedSentence}
            done={done}
            focused={focused}
            onAdopt={() => commit('ai')}
            outcome={session.outcome}
            selectable={selectable}
            stage={session.stage}
          />
        </div>

        <p className="demo-keys" id="demo-key-hints">
          <span><Kbd>Space</Kbd> 提交 Rime 首选</span>
          <span><Kbd>Tab</Kbd> 采纳 AI 建议</span>
          <span><Kbd>←</Kbd><Kbd>→</Kbd> 切换焦点段</span>
          <span><Kbd>Esc</Kbd> 重置</span>
        </p>
      </div>

      <div className="editor-status" aria-hidden="true">
        <span>字数：1,024</span>
        <span>行数：42</span>
        <span>100%</span>
        <span>UTF-8</span>
        <span>Markdown</span>
      </div>

      <p aria-live="polite" className="sr-only">{announcement}</p>
    </div>
  )
}

function Hero() {
  return (
    <section className="hero" id="top">
      <div className="hero-content page-shell">
        <div className="hero-copy">
          <h1>
            <span>让输入更懂上下文，</span>
            <span>让选择始终属于你。</span>
          </h1>
          <p>
            RimeAI 在 Rime 稳定候选之上，加入本地语义排序、零提示词约束整句、段焦点回修、
            无空格中英混输与可检视的语言画像；端上语音听写为可选开启的端上原型。
            AI 只在独立建议位出现，由你主动掌控。
          </p>
          <div className="hero-actions">
            <button className="button button-primary" onClick={() => scrollToSection('how')} type="button">
              看看它如何工作
              <ArrowRight />
            </button>
            <button className="button button-secondary" onClick={() => scrollToSection('privacy')} type="button">
              阅读隐私设计
            </button>
          </div>
          <div className="availability">
            <LaptopIcon />
            <span>Apple Silicon Mac · macOS 14+ · 内部基线，尚未公开发布</span>
          </div>
        </div>
        <div className="hero-stage">
          <EditorDemo />
        </div>
      </div>
      <p className="demo-caption">交互演示 · 候选内容为示意，按键语义与产品一致</p>
    </section>
  )
}

const processSteps = [
  {
    number: '01',
    title: '即时候选',
    detail: 'Rime 同步负责拼音切分、段焦点回修与候选兜底，永不等待 AI。',
  },
  {
    number: '02',
    title: '双延迟本地判断',
    detail: '24M 排序器与用户 LM 先行同步重排，MLX 8-bit 神经臂异步补齐约束整句。',
  },
  {
    number: '03',
    title: '主动确认与回修',
    detail: [{ t: '按 ' }, { k: 'Space' }, { t: ' 提交 Rime 首选，' }, { k: 'Tab' }, { t: ' 采纳 AI 建议，' }, { k: '←' }, { t: ' / ' }, { k: '→' }, { t: ' 可在段间低成本回修。' }],
  },
]

/*
 * Mixed Chinese/English examples are the three mixed-composition scenarios of
 * the frozen keyboard set; the expected text comes straight from the product's
 * mixed-composition resolver tests (ASCII tokens are kept verbatim, no spaces).
 */
const mixedExamples = [
  {
    id: 'api-timeout',
    label: 'API + timeout',
    raw: 'zhegeAPIxuyaozengjiatimeoutpeizhi',
    before: '记得把',
    after: '写进发布说明。',
    parts: [{ t: '这个' }, { t: 'API', ascii: true }, { t: '需要增加' }, { t: 'timeout', ascii: true }, { t: '配置' }],
  },
  {
    id: 'json-doc',
    label: 'JSON 文档',
    raw: 'yigeJSONwendang',
    before: 'README 里的',
    after: '示例，可以直接运行。',
    parts: [{ t: '一个' }, { t: 'JSON', ascii: true }, { t: '文档' }],
  },
  {
    id: 'json-structure',
    label: 'JSON 结构',
    raw: 'shanchuJSONjiegou',
    before: '迁移脚本会先',
    after: '再重建索引。',
    parts: [{ t: '删除' }, { t: 'JSON', ascii: true }, { t: '结构' }],
  },
]

function MixedInputDemo() {
  const [exampleId, setExampleId] = useState(mixedExamples[0].id)
  const [adopted, setAdopted] = useState(false)
  const example = mixedExamples.find((item) => item.id === exampleId) ?? mixedExamples[0]
  const suggestion = example.parts.map((part) => part.t).join('')

  const choose = (id) => {
    setExampleId(id)
    setAdopted(false)
  }

  return (
    <div className="technical-editor">
      <div className="tech-toolbar" aria-hidden="true">
        <span>正文</span>
        <span>PingFang SC</span>
        <span>16</span>
        <b>B</b>
        <i>I</i>
        <span>&lt;/&gt;</span>
      </div>

      <div aria-label="混输示例" className="mixed-examples" role="group">
        {mixedExamples.map((item) => (
          <button
            aria-pressed={item.id === example.id}
            key={item.id}
            onClick={() => choose(item.id)}
            type="button"
          >
            {item.label}
          </button>
        ))}
      </div>

      <p className="tech-sentence">
        {example.before}
        {adopted ? (
          <span className="mixed-result">
            {example.parts.map((part) => (
              part.ascii
                ? <code className="tok-en" key={part.t}>{part.t}</code>
                : <Fragment key={part.t}>{part.t}</Fragment>
            ))}
          </span>
        ) : (
          <span className="pinyin">{example.raw}<span className="caret" /></span>
        )}
        {example.after}
      </p>

      <div className="mini-candidates">
        <button
          className={`semantic-row${adopted ? ' is-done' : ' is-selectable'}`}
          onClick={() => setAdopted((value) => !value)}
          type="button"
        >
          <span className="semantic-main">
            {adopted ? <Check /> : <Spark />}
            <span>{adopted ? '已采纳' : '中英混输'}</span>
          </span>
          <span className="semantic-text">{suggestion}</span>
          <small className="semantic-action">{adopted ? '再点一次重置' : 'Tab 采纳'}</small>
        </button>
      </div>

      <p className="segment-note">
        英文、数字原样带入；完整可解析的纯拼音仍优先留给 Rime
        （<code>women</code> 不会被拆成「我 + men」）。
      </p>
    </div>
  )
}

function WorkflowSection() {
  return (
    <section className="workflow section-light" id="how">
      <div className="page-shell">
        <header className="section-heading centered" data-reveal>
          <h2>不接管 Rime，只让候选更有语境。</h2>
          <p>确定性的主链路保持不变，语义能力只在合适的时机出现。</p>
        </header>

        <div className="process-rail" data-reveal>
          <div className="process-line" aria-hidden="true">
            <span className="signal signal-one" />
            <span className="signal signal-two" />
          </div>
          {processSteps.map((step) => (
            <article className="process-step" key={step.number}>
              <span className="process-icon"><ProcessIcon step={step.number} /></span>
              <div className="step-number" aria-hidden="true">{step.number}</div>
              <div className="step-marker" aria-hidden="true" />
              <h3>{step.title}</h3>
              <p><Rich parts={step.detail} /></p>
            </article>
          ))}
          <span className="delay-note" aria-hidden="true">本地异步建议</span>
        </div>

        <div className="mixed-input" data-reveal>
          <div className="mixed-copy">
            <h3>中文、API 与代码，<br />可以在同一句里自然共存。</h3>
            <span className="accent-stroke" aria-hidden="true" />
            <p>英文标识符、命令、路径与 URL 保持原样，无需手动切换语言。</p>
          </div>
          <MixedInputDemo />
        </div>
      </div>

      <div className="system-strip">
        <div className="system-strip-inner">
          <span className="strip-brand" aria-hidden="true"><BrandMark size={26} /></span>
          <span className="strip-item">rime stable · segment focus</span>
          <i aria-hidden="true" />
          <span className="strip-item strip-item-secondary">24M + MLX 8-bit · on-device semantics</span>
          <i aria-hidden="true" />
          <span className="strip-item strip-item-optional">qwen3-asr · voice prototype</span>
          <i aria-hidden="true" />
          <span className="strip-item strip-item-core">Space for Rime · Tab for AI</span>
          <Check size={16} />
        </div>
      </div>
    </section>
  )
}

const domainPaths = [
  {
    id: 'sentence',
    tab: '整句与段焦点',
    kicker: '双延迟档本地解码',
    title: '一句拼音直出整句，跨段也能低成本回修。',
    description:
      '同步 n-gram beam 先行出句，MLX 8-bit 零提示词拼音约束神经臂在 100–300ms 内按最新请求接管；'
      + '配合段焦点模型，部分选词保留前缀不上屏，←/→ 切段修改后自动按新上下文重推后续段落。',
    status: '冻结集 92.2% · p50 115ms',
    privacy: '零提示词约束 · 失败回退 Rime',
    qualifier: true,
    note: '支持本地与云端双行建议对比 · 任何过期、失活或结构违规帧全部 fail-closed 丢弃',
    stages: [
      { label: '输入', value: '连续拼音 + 标点 + 混输', note: '预编辑区非焦点段展示定稿中文，部分选词不提前上屏' },
      { label: '解码', value: '同步 Beam + MLX 神经臂', note: '词典拼音掩码强制对齐，无开放式胡编；←/→ 切段触发后缀重推' },
      { label: '确认', value: 'Tab 采纳 / 按段复核', note: 'Space 仍提交 Rime 首选；跨段云建议可按段填入再确认' },
    ],
  },
  {
    id: 'mixed',
    tab: '无空格中英混输',
    kicker: '技术写作原生体验',
    title: 'API、timeout 与中文，不必手动切语言。',
    description:
      '连续大写英文作为强边界原样保留，小写技术词结合保守词表与个人短语库识别；'
      + '完整可解析的纯拼音始终优先留给 Rime，避免把正常拼音错拆成英文。',
    status: '保守分段 · 原样保留',
    privacy: '标识符不被擅自改写',
    note: '英文大小写、代码标识符、路径与 URL 保持原样，采纳即同步学习进个人短语库',
    stages: [
      { label: '输入', value: 'zhegeAPIxuyaozengjiatimeoutpeizhi', note: '无需用 Space 充当语言分隔符' },
      { label: '分段', value: '中文 + API + timeout', note: '大写强边界，小写保守识别并优先保护纯拼音' },
      { label: '确认', value: '这个API需要增加timeout配置', note: '独立建议位展示，Tab 明确采纳，英文与数字原样带入' },
    ],
  },
  {
    id: 'profile',
    tab: '语言画像与词库',
    kicker: '透明个人化 · Schema v2',
    title: '越用越像你，每层资产都可见、可管、可删。',
    description:
      '成功上屏文本经空闲固化管线提炼为 L1 短语库（20k 容量与 45 天半衰期淘汰）、L2 分域用户 LM（幂等折叠插值）'
      + '与 L3 风格画像（签名短语自动回灌 L1）；并支持导入 Rime .dict.yaml 领域词库（兼容雾凇词库）。',
    status: '三层画像 · 可装卸词库',
    privacy: '仅存本机 · 不跨用户共享',
    note: '历史原文按 7 天窗口滚动淘汰 · 词库与个人学习同库异表，屏蔽跨全部读音生效',
    stages: [
      { label: '沉淀', value: 'L1 短语 · L2 LM · L3 风格', note: '空闲 ≥10 分钟分批固化；安全输入绝不写入历史' },
      { label: '扩展', value: 'Rime .dict.yaml 领域词库', note: '内置 it-programming 词库，支持独立启停、卸载与词条屏蔽' },
      { label: '控制', value: '可见、可锁定、可清除', note: '按应用分域映射，云压缩可关闭，支持独立导出与永久清除' },
    ],
  },
  {
    id: 'voice',
    tab: '端上语音与翻译',
    kicker: '端上原型 · 可选开启',
    title: '开口即成稿：离线识别、可选润色与语音翻译。',
    description:
      '语音总开关默认关闭。开启后由独立 Voice Helper 调用离线 MLX Qwen3-ASR 流式识别（音频仅驻内存、进程级禁用网络），'
      + '支持 ⌃⇧V 按住说话或右 ⌘ 点按切换、双层三源热词校正、4 风格智能润色与 ⌃⇧T 语音翻译'
      + '（7 种目标语言 + 中英自动互译）；云端深度润色仅在配置云增强后启用，离线或超时自动回退本地润色。',
    status: '内部原型 · 尚未公开释放',
    privacy: '无音频落盘 · 历史仅存本机',
    qualifier: true,
    note: '端上原型：尚未满足公开发布放行门，不构成产品承诺',
    stages: [
      {
        label: '触发',
        value: [{ k: '⌃⇧V' }, { t: ' 按住 · ' }, { k: '右 ⌘' }, { t: ' 点按 · ' }, { k: '⌃⇧T' }, { t: ' 翻译' }],
        note: '录音期间自动静音系统音频，结束后恢复原状态',
      },
      {
        label: '识别',
        value: 'MLX Qwen3-ASR + 双层三源热词',
        note: '融合自定义热词、语言画像与领域词库、会话词条，纠正中英混说',
      },
      {
        label: '成稿',
        value: '智能润色 · 自动粘贴 · 本机统计',
        note: '离线即时去口头语与口吃；本机 SQLite 记录历史与节省时长',
      },
    ],
    defaults: {
      heading: '语音开启后的子开关默认值',
      on: ['自动粘贴（含剪贴板回退）', '交互提示音', '录音时静音系统音频', '本机语音历史与统计', '智能润色', '上屏后纠错学习'],
      off: ['向云端润色/翻译发送热词', 'AX 文档回读（经辅助功能接口读取文档文本）'],
      note: '时限：识别收尾 10s（协议上限 30s）· 云端润色 6s · 云端翻译 10s，超时均回退本地、不丢字。',
    },
  },
  {
    id: 'cloud',
    tab: '云增强与续写',
    kicker: '默认关闭 · 独立 Broker',
    title: '只在你配置后联网，做受控整句、续写与深度润色。',
    description:
      '独立 cloud broker 仅在录入 API Key 后直连智谱 glm-5.3-flash；键盘请求不携带候选池，'
      + '只返回经结构门校验的整句纠错（支持跨段按段接受）与上屏后续写联想 chip（默认关闭）；语音深度润色与翻译同走该 broker。',
    status: 'Opt-in · 固定白名单',
    privacy: '本地 Daemon 永久无网络',
    note: '所有云结果均须结构校验并由用户显式确认；Secure Event Input 时全链路自动阻断',
    stages: [
      { label: '整句纠错', value: '单一宽松策略 · Generate/Abstain', note: '允许纠正前后鼻音、平翘舌与错键，多段建议可按段复核' },
      { label: '上屏续写', value: '单条 Chip · 8s 自动消失', note: '默认关闭；上屏后轻量联想，Tab 或点击采纳，任意其他按键即撤' },
      { label: '语音增强', value: '4 风格深度润色 · 7 种目标语言 + 中英互译', note: '润色限时 6s、翻译限时 10s，离线或超时自动回退，不丢字' },
    ],
  },
]

const modelLayers = [
  {
    label: '候选排序',
    model: '24M · INT8/FP',
    status: '等价性 99.38%',
    qualifier: true,
    detail: '本地 24M 拼音感知排序器融合 n-gram 与 L2 用户 LM，Release 使用 INT8 ONNX。',
  },
  {
    label: '约束整句',
    model: 'MLX · 8-bit',
    status: '92.2% · p50 115ms',
    qualifier: true,
    detail: 'Qwen2.5-0.5B 零提示词拼音约束解码，持久共享缓存，异步迟到帧接管。',
  },
  {
    label: '端上语音',
    model: 'Qwen3-ASR',
    status: '端上原型 · 可选开启',
    detail: 'MLX 8-bit 离线流式识别 + 双层热词校正 + 离线润色；独立 helper 进程隔离。',
  },
  {
    label: '可选云增强',
    model: 'glm-5.3-flash',
    status: '默认关闭 · Opt-in',
    detail: '独立 broker 直连；覆盖整句生成、上屏续写与语音深度润色/翻译。',
  },
]

function DomainSection() {
  const [pathId, setPathId] = useState('sentence')
  const ids = useMemo(() => domainPaths.map((path) => path.id), [])
  const onKeyDown = useRovingFocus(ids, pathId, (id) => `domain-tab-${id}`, setPathId)
  const activePath = domainPaths.find((path) => path.id === pathId) ?? domainPaths[0]

  return (
    <section className="domain section-light" id="domain">
      <div className="page-shell">
        <header className="section-heading domain-heading" data-reveal>
          <span className="section-kicker">产品能力</span>
          <h2>从候选、整句到语音，<br />更懂你的表达。</h2>
          <p>
            为中文技术写作与日常高效输入打造：保留 Rime 的确定性主链，
            用双延迟本地语义、语言画像与可选的端上语音减少翻页、选词与切语成本。
          </p>
        </header>

        <div className="domain-workbench" data-reveal>
          <div className="domain-paths">
            <div className="path-intro">
              <small>选择能力</small>
              <strong>每种增强，都有明确边界。</strong>
            </div>

            <div aria-label="产品能力" className="domain-tablist" role="tablist">
              {domainPaths.map((path) => {
                const isActive = pathId === path.id
                return (
                  <button
                    aria-controls="domain-path-panel"
                    aria-selected={isActive}
                    className={isActive ? 'is-active' : ''}
                    data-roving-id={path.id}
                    id={`domain-tab-${path.id}`}
                    key={path.id}
                    onClick={() => setPathId(path.id)}
                    onKeyDown={onKeyDown}
                    role="tab"
                    tabIndex={isActive ? 0 : -1}
                    type="button"
                  >
                    <span>{path.tab}</span>
                    <small>{path.kicker}</small>
                    <i aria-hidden="true"><ArrowRight size={16} /></i>
                  </button>
                )
              })}
            </div>

            <div className="domain-rule">
              <Spark size={18} />
              <p>
                <strong>默认规则</strong>
                不用日常输入做跨用户训练，个人画像由你控制。
              </p>
            </div>
          </div>

          <div
            aria-labelledby={`domain-tab-${activePath.id}`}
            className="domain-path-panel"
            id="domain-path-panel"
            role="tabpanel"
            tabIndex={0}
          >
            <div className="path-panel-heading">
              <div>
                <span>{activePath.kicker}</span>
                <h3>{activePath.title}</h3>
                <p>{activePath.description}</p>
              </div>
              <div className="path-status">
                <strong>{activePath.status}</strong>
                {activePath.qualifier && <MetricQualifier />}
                <small>{activePath.privacy}</small>
              </div>
            </div>

            <div className="data-pipeline">
              {activePath.stages.map((stage, index) => (
                <article key={stage.label}>
                  <span>{String(index + 1).padStart(2, '0')} · {stage.label}</span>
                  <strong><Rich parts={stage.value} /></strong>
                  <small>{stage.note}</small>
                </article>
              ))}
            </div>

            {activePath.defaults && (
              <div className="feature-defaults">
                <h4>{activePath.defaults.heading}</h4>
                <div className="feature-defaults-grid">
                  <section className="feature-default is-on" aria-label="默认开启">
                    <h5><span className="default-glyph" aria-hidden="true">开</span>默认开启<small>均可单独关闭</small></h5>
                    <ul>
                      {activePath.defaults.on.map((item) => <li key={item}>{item}</li>)}
                    </ul>
                  </section>
                  <section className="feature-default is-off" aria-label="默认关闭">
                    <h5><LockIcon />默认关闭<small>需单独开启</small></h5>
                    <ul>
                      {activePath.defaults.off.map((item) => <li key={item}>{item}</li>)}
                    </ul>
                  </section>
                </div>
                <p className="feature-defaults-note">{activePath.defaults.note}</p>
              </div>
            )}

            <div className="local-only-note">
              <Check size={18} />
              <span>{activePath.note}</span>
            </div>
          </div>
        </div>

        <div className="model-stack" data-reveal>
          <div className="model-stack-heading">
            <small>当前技术路径</small>
            <h3>本地优先，<br />云增强可选。</h3>
          </div>
          {modelLayers.map((layer) => (
            <article key={layer.label}>
              <span>{layer.label}</span>
              <strong>{layer.model}</strong>
              <em>{layer.status}</em>
              {layer.qualifier && <MetricQualifier />}
              <p>{layer.detail}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}

function DeviceEngine() {
  return (
    <div className="engine-cube" aria-label="设备内语义引擎">
      <BrandMark size={32} />
      <strong>本地语义与语音引擎</strong>
      <span>24M 排序 · MLX 约束整句 · Qwen3-ASR</span>
      <span>进程级无网络 · 失败回退 Rime</span>
    </div>
  )
}

const privacyModes = [
  {
    id: 'strict',
    label: '严格',
    description: '仅当前拼音与候选',
    rangeLabel: '只读当前组合',
    context: 'zhu shu ju ku',
  },
  {
    id: 'standard',
    label: '标准',
    description: '当前应用会话最近上屏的有限文本',
    rangeLabel: '最近上屏 · 当前应用',
    context: '这个服务使用 PostgreSQL 作为',
  },
  {
    id: 'smart',
    label: '智能',
    description: '显式开启后读取有限光标前文本',
    rangeLabel: '有限光标前文本 · 显式开启',
    context: '我们正在迁移服务。这个服务使用 PostgreSQL 作为',
  },
]

function PrivacySection() {
  const [modeId, setModeId] = useState('strict')
  const [cloudEnabled, setCloudEnabled] = useState(false)
  const ids = useMemo(() => privacyModes.map((mode) => mode.id), [])
  const onModeKeyDown = useRovingFocus(ids, modeId, (id) => `context-mode-${id}`, setModeId)
  const activeMode = privacyModes.find((mode) => mode.id === modeId) ?? privacyModes[0]

  return (
    <section className="privacy section-dark" id="privacy">
      <div className="page-shell">
        <header className="section-heading privacy-heading" data-reveal>
          <h2>本地优先，<br className="mobile-break" />云端由你决定。</h2>
          <p>
            候选、约束整句与混输默认全部在设备端完成，本地推理与语音 worker 均无 INET；
            端上语音为可选开启的原型，识别在本机离线完成。
            云增强只有在你配置 API Key 并启用后才运行；安全输入时，自动阻断 AI、上下文、历史、语音与自动粘贴。
          </p>
        </header>

        <div className="privacy-console" data-reveal>
          <div className="mode-panel">
            <h3>上下文由你决定</h3>
            <div aria-label="上下文模式" className="mode-options" role="radiogroup">
              {privacyModes.map((mode) => {
                const isActive = modeId === mode.id
                return (
                  <button
                    aria-checked={isActive}
                    className={isActive ? 'is-active' : ''}
                    data-roving-id={mode.id}
                    id={`context-mode-${mode.id}`}
                    key={mode.id}
                    onClick={() => setModeId(mode.id)}
                    onKeyDown={onModeKeyDown}
                    role="radio"
                    tabIndex={isActive ? 0 : -1}
                    type="button"
                  >
                    <span className="mode-icon"><ContextIcon type={mode.id} /></span>
                    <span>
                      <strong>{mode.label}</strong>
                      <small>{mode.description}</small>
                    </span>
                    <i aria-hidden="true" />
                  </button>
                )
              })}
            </div>
          </div>

          <div className="boundary-panel">
            <div className="context-preview">
              <small>{activeMode.rangeLabel}</small>
              <p>{activeMode.context}</p>
              <div className="pinyin-preview" aria-hidden="true">zhu shu ju ku<span className="caret" /></div>
            </div>

            <span className="flow-arrow" aria-hidden="true"><ArrowRight size={26} /></span>
            <DeviceEngine />
            <span className={`flow-line ${cloudEnabled ? 'is-open' : 'blocked'}`} aria-hidden="true">
              {!cloudEnabled && <><i /><b>×</b></>}
            </span>

            <div className="network-boundary">
              <svg aria-hidden="true" fill="none" viewBox="0 0 64 48">
                <path d="M17 39h32a10 10 0 0 0 1-19.9A16 16 0 0 0 19.7 15 12 12 0 0 0 17 39Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
              </svg>
              <strong>互联网</strong>
              <span aria-live="polite">{cloudEnabled ? '仅独立 broker 可发起已配置请求' : '默认无输入内容进入网络路径'}</span>
            </div>
          </div>
        </div>

        <div className={`offline-lock ${cloudEnabled ? 'is-on' : ''}`} data-reveal>
          <div className="lock-symbol" aria-hidden="true">
            <svg fill="none" viewBox="0 0 28 28">
              <path d="M7 20h14a4 4 0 0 0 .5-8A7 7 0 0 0 8 10a5 5 0 0 0-1 10Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
            </svg>
          </div>
          <div className="lock-title">
            <strong>云端增强</strong>
            <p>默认关闭；启用后仅由独立 broker 连接你配置的固定云服务。</p>
          </div>
          <button
            aria-checked={cloudEnabled}
            aria-label="云端增强演示开关"
            className="toggle"
            onClick={() => setCloudEnabled((value) => !value)}
            role="switch"
            type="button"
          >
            <span aria-hidden="true" />
          </button>
          <em aria-hidden="true">{cloudEnabled ? '已开启' : '已关闭'}</em>
        </div>

        <div className="privacy-commitments">
          <article data-reveal>
            <CommitmentIcon type="secure" />
            <div>
              <h3>安全输入全链路阻断</h3>
              <p>检测到系统安全输入时，阻断 AI、云请求、历史写入、语音与自动粘贴并清空上下文。</p>
            </div>
          </article>
          <article data-reveal>
            <CommitmentIcon type="isolation" />
            <div>
              <h3>进程与会话双重隔离</h3>
              <p>不同应用会话互不串读；本地 daemon 与语音 worker 禁用 INET，音频仅驻内存不落盘。</p>
            </div>
          </article>
          <article data-reveal>
            <CommitmentIcon type="clear" />
            <div>
              <h3>开关默认值清楚可见</h3>
              <p>
                键盘历史、语音历史与统计、语言画像和领域词库分栏管理，可独立导出与永久清除。
                语音开启后，自动粘贴、提示音、媒体静音、本机历史、智能润色与纠错学习默认开启且均可关闭；
                云端热词与 AX 文档回读须单独开启，默认关闭。
              </p>
            </div>
          </article>
        </div>

        <p className="privacy-qualifier">
          页面开关仅用于演示 · 本地 daemon 与语音 worker 均无 INET，云联网只发生在独立、显式启用的 broker
        </p>
      </div>
    </section>
  )
}

const roadmapSteps = [
  {
    phase: '01',
    title: '内部基线',
    state: 'current',
    status: '当前阶段',
    detail: '键盘主链、双延迟整句、语言画像与领域词库已内部收口',
  },
  {
    phase: '02',
    title: '质量与盲打度量',
    state: 'active',
    status: '进行中',
    detail: '盲打 first-shot 冻结集、决策反馈日志与蒸馏模型门禁',
  },
  {
    phase: '03',
    title: '发布与平台验证',
    state: 'pending',
    status: '尚未放行',
    detail: '签名、公证、清洁机、真实宿主、安全输入与语音放行门',
  },
  {
    phase: '04',
    title: '公开预览',
    state: 'planned',
    status: '以证据推进',
    detail: 'Apple Silicon Mac · macOS 14+ · 以真实指标迭代',
  },
]

const targets = [
  { id: 'space', value: 'Space', tag: '产品合同', label: ['提交 Rime 首选，基础键盘语义不变'] },
  { id: 'tab', value: 'Tab', tag: '产品合同', label: ['显式采纳当前语义建议或续写联想'] },
  {
    id: 'zero',
    value: '0',
    tag: '产品合同',
    label: ['键盘态自动上屏、默认云端请求与音频落盘', '语音自动粘贴与润色均可关闭'],
  },
  {
    id: 'accuracy',
    value: '92.2%',
    tag: '冻结集基线',
    label: ['MLX 8-bit 零提示词约束整句句准确率（p50 115ms）'],
    qualifier: true,
  },
]

function RoadmapSection() {
  return (
    <section className="roadmap section-light" id="roadmap">
      <div className="page-shell">
        <header className="section-heading roadmap-heading" data-reveal>
          <h2>先证明可靠，<br className="mobile-break" />再交到你的键盘上。</h2>
          <p>
            当前仍是内部基线，不提供下载。公开预览前必须完成签名、公证、
            清洁机安装、真实宿主与安全输入验证。
          </p>
        </header>

        <ol aria-label="发布路线" className="roadmap-line" data-reveal>
          {roadmapSteps.map((step) => (
            <article className={`is-${step.state}`} data-state={step.state} key={step.phase}>
              <div className="roadmap-title">
                <span aria-hidden="true">{step.phase}</span>
                <h3>{step.title}</h3>
                <em className="roadmap-status">{step.state === 'pending' && <LockIcon />}{step.status}</em>
              </div>
              <div className="roadmap-track" aria-hidden="true"><i /></div>
              <p>{step.detail}</p>
            </article>
          ))}
        </ol>

        <div className="targets-heading" data-reveal>
          <h3>写在交互里的硬约束</h3>
        </div>
        <div className="targets-grid">
          {targets.map((target) => (
            <article data-reveal key={target.id}>
              <div>
                <strong>{target.value}</strong>
                <em>{target.tag}</em>
              </div>
              {target.label.map((line) => <p key={line}>{line}</p>)}
              {target.qualifier && <MetricQualifier />}
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}

function FinalCta() {
  return (
    <section className="final-cta">
      <div className="page-shell final-cta-inner">
        <div className="cta-orbit" aria-hidden="true">
          <i />
          <i />
          <i />
          <BrandMark size={42} />
        </div>
        <div className="cta-copy" data-reveal>
          <h2>中文输入的确定性，加上语义理解的新可能。</h2>
          <p>Rime 始终兜底，AI 始终建议。RimeAI 正面向 Apple Silicon Mac 进行发布前验证。</p>
          <div>
            <a className="button button-primary" href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
              在 GitHub 查看源码
              <ArrowRight />
            </a>
            <button className="text-link" onClick={() => scrollToSection('top')} type="button">
              回到产品演示
              <ArrowRight />
            </button>
          </div>
        </div>
      </div>
    </section>
  )
}

function Footer() {
  return (
    <footer className="site-footer">
      <div className="page-shell footer-inner">
        <a className="brand" href="#top" aria-label="RimeAI 首页">
          <BrandMark />
          <span>RimeAI</span>
        </a>
        <div className="footer-note">
          <LaptopIcon />
          Apple Silicon Mac · macOS 14+ · 尚未公开发布
        </div>
        <nav aria-label="页脚导航">
          <a href="#how">工作方式</a>
          <span aria-hidden="true">/</span>
          <a href="#domain">产品能力</a>
          <span aria-hidden="true">/</span>
          <a href="#privacy">隐私</a>
          <span aria-hidden="true">/</span>
          <a href="#roadmap">发布路线</a>
          <span aria-hidden="true">/</span>
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">GitHub · wuxiao/RimeAI</a>
        </nav>
      </div>
    </footer>
  )
}

function App() {
  useEffect(() => {
    const elements = Array.from(document.querySelectorAll('[data-reveal]'))
    const reduceMotion = prefersReducedMotion()

    if (reduceMotion || !('IntersectionObserver' in window)) {
      elements.forEach((element) => element.classList.add('is-visible'))
      return undefined
    }

    // A 60px bottom inset reveals a block once roughly that much of it is on
    // screen. It works for any block height, unlike a fixed ratio threshold.
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible')
            observer.unobserve(entry.target)
          }
        })
      },
      { rootMargin: '0px 0px -60px 0px', threshold: 0 },
    )

    elements.forEach((element) => observer.observe(element))
    return () => observer.disconnect()
  }, [])

  return (
    <>
      <a className="skip-link" href="#main-content">跳到主要内容</a>
      <Header />
      <main id="main-content" tabIndex={-1}>
        <Hero />
        <WorkflowSection />
        <DomainSection />
        <PrivacySection />
        <RoadmapSection />
        <FinalCta />
      </main>
      <Footer />
    </>
  )
}

export default App
