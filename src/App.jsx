import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'

const GITHUB_URL = 'https://github.com/wuxiao/RimeAI'
const THEME_STORAGE_KEY = 'rimeai-theme'
const METRIC_QUALIFIER = '974 样本冻结集 · Release 暂未打包 MLX'

const ArrowRight = ({ size = 16 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M5 12h13M13.5 6.5 19 12l-5.5 5.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.75" />
  </svg>
)

const ArrowUpRight = ({ size = 15 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M7 17 17 7M9 7h8v8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.75" />
  </svg>
)

const Check = ({ size = 15 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="m5 12.5 4.2 4.3L19 7.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
  </svg>
)

const ResetIcon = ({ size = 15 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M19 8V4m0 0h-4m4 0-3 3a7 7 0 1 0 1.5 7.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
  </svg>
)

const SystemIcon = ({ size = 14 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <rect x="3.5" y="5" width="17" height="11.5" rx="2" stroke="currentColor" strokeWidth="1.7" />
    <path d="M9 20h6M12 16.5V20" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
  </svg>
)

const SunIcon = ({ size = 14 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.7" />
    <path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M18.4 5.6l-1.6 1.6M7.2 16.8l-1.6 1.6" stroke="currentColor" strokeLinecap="round" strokeWidth="1.7" />
  </svg>
)

const MoonIcon = ({ size = 14 }) => (
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

const ShieldIcon = ({ size = 18 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M12 3.5 5 6.3v5.4c0 4.4 3 7.6 7 8.8 4-1.2 7-4.4 7-8.8V6.3L12 3.5Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.6" />
    <path d="m9.2 12 1.9 1.9 3.8-4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
  </svg>
)

const LayersIcon = ({ size = 18 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="m12 4.5 8 4-8 4-8-4 8-4Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.6" />
    <path d="m4.5 12.5 7.5 3.8 7.5-3.8M4.5 16.5l7.5 3.8 7.5-3.8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
  </svg>
)

const SlidersIcon = ({ size = 18 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1" stroke="currentColor" strokeLinecap="round" strokeWidth="1.6" />
    <circle cx="15" cy="7" r="2" stroke="currentColor" strokeWidth="1.6" />
    <circle cx="9" cy="12" r="2" stroke="currentColor" strokeWidth="1.6" />
    <circle cx="17" cy="17" r="2" stroke="currentColor" strokeWidth="1.6" />
  </svg>
)

const CloudIcon = ({ size = 18 }) => (
  <svg aria-hidden="true" className="icon" fill="none" height={size} viewBox="0 0 24 24" width={size}>
    <path d="M7.5 18.5h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6.5 9.6 4.5 4.5 0 0 0 7.5 18.5Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
  </svg>
)

const BrandMark = ({ size = 24 }) => (
  <svg aria-hidden="true" className="brand-mark" fill="none" height={size} viewBox="0 0 40 40" width={size}>
    <path d="M8 33V7h13c7 0 11 3.8 11 10s-4.2 10-11 10H12" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="4.2" />
    <path d="m21 27 11 8M8 7l7 7" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="4.2" />
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

function prefersReducedMotion() {
  return typeof window !== 'undefined'
    && typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function scrollToSection(id) {
  const target = document.getElementById(id)
  if (!target) {
    return
  }
  target.scrollIntoView({
    behavior: prefersReducedMotion() ? 'auto' : 'smooth',
    block: 'start',
  })
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
    <div aria-label="颜色主题" className="theme-switch" onKeyDown={onKeyDown} role="radiogroup">
      {themes.map(({ id, label, Icon }) => {
        const isActive = theme === id
        return (
          <button
            aria-checked={isActive}
            aria-label={label}
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
          </button>
        )
      })}
    </div>
  )
}

function Header() {
  return (
    <header className="site-header">
      <div className="page-shell header-inner">
        <a className="brand" href="#top" aria-label="RimeAI 首页">
          <span className="brand-badge" aria-hidden="true">
            <BrandMark size={17} />
          </span>
          <span>RimeAI</span>
        </a>

        <nav aria-label="主导航" className="main-nav">
          <a href="#how">工作方式</a>
          <a href="#domain">产品能力</a>
          <a href="#privacy">隐私边界</a>
          <a href="#roadmap">发布路线</a>
        </nav>

        <div className="header-tools">
          <ThemeSwitch />
          <a className="header-github" href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
            <span>GitHub</span>
            <ArrowUpRight size={14} />
          </a>
        </div>
      </div>
    </header>
  )
}

/*
 * Hero demo: a real-world technical writing homophone ambiguity.
 * Without document context, general pinyin ranks 实力 first for
 * "xian jian cha suo you shi li", while the surrounding deployment checklist
 * calls for 实例. Space always commits Rime's first choice immediately, Tab
 * adopts a ready semantic suggestion, and ←/→ switch segment focus.
 */
const demoLead = {
  id: 'lead',
  pinyin: 'xin ji qun qi dong hou',
  draft: '新集群启动后',
  rime: ['新集群启动后'],
  ai: '新集群启动后',
}

const demoTarget = {
  id: 'target',
  pinyin: 'xian jian cha suo you shi li',
  draft: '先检查所有实力',
  rime: ['先检查所有实力', '先检查所有实例', '先检查所有示例'],
  ai: '先检查所有实例',
}

const DEMO_ANALYSIS_MS = 650
const DEMO_RESET_MS = 7500

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
    ? `预编辑区：焦点段拼音 ${demoLead.pinyin}，逗号，后缀定稿 ${demoTarget.draft}。`
    : `预编辑区：前缀定稿 ${demoLead.draft}，逗号，焦点段拼音 ${demoTarget.pinyin}。`
}

function DemoComposition({ done, outcome, committedTarget, focusId, onFocusSegment }) {
  if (done) {
    return (
      <p aria-hidden="true" className="composition">
        <span>{demoLead.draft}，</span>
        <strong className={`committed-token is-${outcome}`}>{committedTarget}</strong>
        <span className="caret" />
      </p>
    )
  }

  return (
    <p aria-hidden="true" className="composition">
      <button
        className={`segment${focusId === demoLead.id ? ' is-focused' : ''}`}
        onClick={() => onFocusSegment(demoLead.id)}
        tabIndex={-1}
        type="button"
      >
        {focusId === demoLead.id ? (
          <><span className="pinyin">{demoLead.pinyin}</span><span className="caret" /></>
        ) : (
          demoLead.draft
        )}
      </button>
      <span className="literal">，</span>
      <button
        className={`segment${focusId === demoTarget.id ? ' is-focused' : ''}`}
        onClick={() => onFocusSegment(demoTarget.id)}
        tabIndex={-1}
        type="button"
      >
        {focusId === demoTarget.id ? (
          <><span className="pinyin">{demoTarget.pinyin}</span><span className="caret" /></>
        ) : (
          demoTarget.draft
        )}
      </button>
    </p>
  )
}

function DemoPopover({ done, outcome, committedSentence, focused, stage, selectable, onCommitRime, onAdoptAi, onReset }) {
  if (done) {
    return (
      <div className={`demo-outcome is-${outcome}`}>
        <div className="outcome-head">
          <span className="outcome-badge">
            <Check size={13} />
            {outcome === 'ai' ? '已采纳语义建议' : '已提交 Rime 首选'}
          </span>
          <button className="outcome-reset" onClick={onReset} type="button">
            重新演示
          </button>
        </div>
        <strong>{committedSentence}</strong>
      </div>
    )
  }

  const analyzing = stage === 'analyzing'
  return (
    <>
      <div className="candidate-row">
        <div className="candidate-items">
          {focused.rime.map((candidate, index) => (
            index === 0 ? (
              <button
                className="candidate-chip is-first"
                key={candidate}
                onClick={onCommitRime}
                title="点击或按 Space 提交 Rime 首选"
                type="button"
              >
                <b>{index + 1}</b>
                <span>{candidate}</span>
              </button>
            ) : (
              <span className="candidate-chip" key={candidate}>
                <b>{index + 1}</b>
                <span>{candidate}</span>
              </span>
            )
          ))}
        </div>
        <em className="row-tag">Rime</em>
      </div>

      <button
        aria-busy={analyzing}
        aria-label={analyzing ? '本地模型分析中' : `语义建议：${focused.ai}`}
        className={`semantic-row is-${stage}${selectable ? ' is-selectable' : ''}`}
        disabled={!selectable}
        onClick={onAdoptAi}
        type="button"
      >
        <span className="semantic-main">
          <span className={`ai-pill${analyzing ? ' is-loading' : ''}`} aria-hidden="true">
            {analyzing ? '···' : 'AI'}
          </span>
          <span className="semantic-value">{analyzing ? '本地模型分析中…' : focused.ai}</span>
        </span>
        <span className="semantic-meta">
          {analyzing && '独立建议位 · 不阻塞输入'}
          {!analyzing && selectable && (
            <span className="semantic-action-hint">
              <Kbd>Tab</Kbd> 采纳
            </span>
          )}
          {!analyzing && !selectable && '与 Rime 首选一致'}
        </span>
      </button>
    </>
  )
}

function EditorDemo() {
  const [session, setSession] = useState({ focusId: demoTarget.id, stage: 'analyzing', outcome: null })
  const documentRef = useRef(null)

  const focused = session.focusId === demoLead.id ? demoLead : demoTarget
  const done = session.stage === 'done'
  const selectable = session.stage === 'ready' && focused.ai !== focused.rime[0]
  const committedTarget = session.outcome === 'ai' ? demoTarget.ai : demoTarget.draft
  const committedSentence = `${demoLead.draft}，${committedTarget}`

  const reset = useCallback(() => {
    setSession({ focusId: demoTarget.id, stage: 'analyzing', outcome: null })
  }, [])

  const moveFocus = useCallback((segmentId) => {
    setSession((current) => (
      current.focusId === segmentId && current.stage !== 'done'
        ? current
        : { focusId: segmentId, stage: 'analyzing', outcome: null }
    ))
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
        if (session.focusId === demoTarget.id) {
          event.preventDefault()
          moveFocus(demoLead.id)
        }
        break
      case 'ArrowRight':
        if (session.focusId === demoLead.id) {
          event.preventDefault()
          moveFocus(demoTarget.id)
        }
        break
      case 'Escape':
        event.preventDefault()
        reset()
        break
      case 'Tab':
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
    <div className="editor-window">
      <div className="editor-chrome">
        <div className="traffic-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div className="editor-filename">
          发布检查.md<span>已编辑</span>
        </div>
        <button aria-label="重新演示" className="editor-reset" onClick={reset} title="重新演示" type="button">
          <ResetIcon size={14} />
        </button>
      </div>

      <div
        aria-describedby="demo-key-hints"
        aria-label="输入演示：聚焦后可用键盘操作"
        className={`editor-canvas${done ? ' is-committed' : ''}`}
        onKeyDown={handleKeyDown}
        ref={documentRef}
        role="group"
        tabIndex={0}
      >
        <p className="doc-heading">搜索服务灰度发布</p>
        <p className="doc-body">新集群已完成镜像拉取，健康检查端口全部正常响应。</p>
        <p className="doc-body">今晚十点切流前，先在预发环境跑一遍全量回归，并保留上一版本用于快速回滚。</p>
        <p className="doc-lead">上线前确认项：</p>

        <DemoComposition
          committedTarget={committedTarget}
          done={done}
          focusId={session.focusId}
          onFocusSegment={moveFocus}
          outcome={session.outcome}
        />
        <span className="sr-only">{done ? `已上屏：${committedSentence}` : preeditText}</span>

        <div className="ime-popover">
          <DemoPopover
            committedSentence={committedSentence}
            done={done}
            focused={focused}
            onAdoptAi={() => commit('ai')}
            onCommitRime={() => commit('rime')}
            onReset={reset}
            outcome={session.outcome}
            selectable={selectable}
            stage={session.stage}
          />
        </div>
      </div>

      <div className="editor-footer">
        <p className="demo-keys" id="demo-key-hints">
          <span><Kbd>Space</Kbd> Rime 首选</span>
          <span><Kbd>Tab</Kbd> 采纳</span>
          <span><Kbd>←</Kbd><Kbd>→</Kbd> 切段</span>
          <span><Kbd>Esc</Kbd> 重置</span>
        </p>
        <span className="editor-meta" aria-hidden="true">Markdown · UTF-8</span>
      </div>

      <p aria-live="polite" className="sr-only">{announcement}</p>
    </div>
  )
}

function Hero() {
  return (
    <section className="hero" id="top">
      <div className="page-shell hero-grid">
        <div className="hero-copy">
          <p className="hero-eyebrow">
            <span className="status-dot" aria-hidden="true" />
            Apple Silicon Mac · macOS 14+ · 内部基线，尚未公开发布
          </p>
          <h1>
            让输入更懂上下文，
            <br />
            让选择始终属于你。
          </h1>
          <p className="hero-lead">
            面向中文技术写作与日常高效输入的本地优先语义输入引擎。在 Rime 确定性候选之上，
            叠加本地语义排序、零提示词约束整句、段焦点回修、无空格中英混输与可选的端上语音听写原型。
          </p>
          <div className="hero-actions">
            <button className="btn btn-primary" onClick={() => scrollToSection('how')} type="button">
              看看它如何工作
              <ArrowRight size={15} />
            </button>
            <button className="btn btn-secondary" onClick={() => scrollToSection('privacy')} type="button">
              阅读隐私设计
            </button>
          </div>
          <dl className="hero-facts">
            <div>
              <dt>按键契约</dt>
              <dd><Kbd>Space</Kbd> 首选 · <Kbd>Tab</Kbd> 采纳</dd>
            </div>
            <div>
              <dt>约束整句</dt>
              <dd>92.2% · p50 115ms</dd>
            </div>
            <div>
              <dt>默认网络</dt>
              <dd>本地无 INET · 云端关闭</dd>
            </div>
          </dl>
        </div>

        <div className="hero-stage">
          <EditorDemo />
          <p className="stage-caption">交互演示 · 点击候选或聚焦编辑区按键体验，按键语义与产品一致</p>
        </div>
      </div>
    </section>
  )
}

const processSteps = [
  {
    number: '01',
    title: 'Rime 同步兜底',
    detail: '受控 librime 同步负责拼音切分、段焦点回修与数字候选。组合期间候选位置永不跳动，永不等待 AI。',
  },
  {
    number: '02',
    title: '双延迟本地语义',
    detail: '24M 排序器与用户 LM 先行同步重排并由词典约束 beam 出句；MLX 8-bit 零提示词神经臂随后按最新请求异步接管。',
  },
  {
    number: '03',
    title: '主动确认与段回修',
    detail: [
      { t: '按 ' }, { k: 'Space' }, { t: ' 提交 Rime 首选，' },
      { k: 'Tab' }, { t: ' 显式采纳建议位，' },
      { k: '←' }, { t: ' / ' }, { k: '→' }, { t: ' 在拼音段间切段并自动重推后续段落。' },
    ],
  },
]

/*
 * Three real mixed-composition scenarios from the frozen keyboard set:
 * uppercase acronyms stay verbatim, lowercase tech tokens use conservative
 * matching, and valid pure pinyin stays with Rime.
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
    <div className="mixed-card">
      <div className="mixed-card-bar">
        <div aria-label="混输示例" className="mixed-tabs" role="group">
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
        <span className="mixed-card-tag" aria-hidden="true">无空格混输</span>
      </div>

      <div className="mixed-card-body">
        <p className="mixed-sentence">
          {example.before}
          {adopted ? (
            <span className="mixed-adopted">
              {example.parts.map((part, index) => (
                part.ascii
                  ? <code className="tok-en" key={`${part.t}-${index}`}>{part.t}</code>
                  : <Fragment key={`${part.t}-${index}`}>{part.t}</Fragment>
              ))}
            </span>
          ) : (
            <span className="mixed-raw">{example.raw}<span className="caret" /></span>
          )}
          {example.after}
        </p>

        <button
          className={`semantic-row mixed-row${adopted ? ' is-done' : ' is-selectable'}`}
          onClick={() => setAdopted((value) => !value)}
          type="button"
        >
          <span className="semantic-main">
            <span className={`ai-pill${adopted ? ' is-ok' : ''}`} aria-hidden="true">
              {adopted ? <Check size={12} /> : '混输'}
            </span>
            <span className="semantic-value">{suggestion}</span>
          </span>
          <span className="semantic-meta">
            {adopted ? '再次点击重置' : <span className="semantic-action-hint"><Kbd>Tab</Kbd> 采纳</span>}
          </span>
        </button>

        <p className="mixed-footnote">
          英文、数字与路径原样带入；完整可解析的纯拼音仍优先留给 Rime（例如 <code>women</code> 不会被拆成「我 + men」）。
        </p>
      </div>
    </div>
  )
}

function WorkflowSection() {
  return (
    <section className="section" id="how">
      <div className="page-shell">
        <header className="section-header" data-reveal>
          <span className="section-index">01 · 工作方式</span>
          <h2>不接管 Rime，只让候选更有语境。</h2>
          <p>确定性的主链路保持不变，语义增强只在独立建议位按需出现。</p>
        </header>

        <ol className="steps-grid" data-reveal>
          {processSteps.map((step) => (
            <li className="step-card" key={step.number}>
              <span className="step-num" aria-hidden="true">{step.number}</span>
              <h3>{step.title}</h3>
              <p><Rich parts={step.detail} /></p>
            </li>
          ))}
        </ol>

        <div className="mixed-block" data-reveal>
          <div className="mixed-copy">
            <span className="section-index">无空格中英混输</span>
            <h3>中文、API 与代码标识符，在同一句里自然共存。</h3>
            <p>
              不需要用空格充当中英文分隔符，也不必来回切换输入法。连续大写英文作为强边界原样保留，
              小写技术词保守识别，避免误伤正常拼音。
            </p>
          </div>
          <MixedInputDemo />
        </div>
      </div>
    </section>
  )
}

const domainPaths = [
  {
    id: 'sentence',
    tab: '整句与段焦点',
    kicker: '双延迟本地解码',
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
      + '默认支持 Fn 点按切换，也可设为右 ⌘ 点按或自定义 ⌃⇧/⌥⇧ 快捷键，内置双层三源热词校正、4 风格智能润色与 ⌃⇧T 语音翻译'
      + '（7 种目标语言 + 中英自动互译）；云端深度润色仅在配置云增强后启用，离线或超时自动回退本地润色。',
    status: '内部原型 · 尚未公开释放',
    privacy: '无音频落盘 · 历史仅存本机',
    qualifier: true,
    note: '端上原型：尚未满足公开发布放行门，不构成产品承诺',
    stages: [
      {
        label: '触发',
        value: [{ k: 'Fn' }, { t: ' / ' }, { k: '右 ⌘' }, { t: ' 点按 · ' }, { k: '⌃⇧T' }, { t: ' 翻译' }],
        note: '默认 Fn 点按开始/结束，也可录制 ⌃⇧/⌥⇧ 组合；录音期间自动静音系统媒体并恢复原状态',
      },
      {
        label: '识别',
        value: 'MLX Qwen3-ASR + 双层三源热词',
        note: '融合自定义热词、语言画像与领域词库、会话词条，确定性纠正中英混说拼写',
      },
      {
        label: '成稿',
        value: '智能润色 · 自动粘贴 · 本机统计',
        note: '离线即时去口头语与口吃；本机 SQLite 记录历史、语速与估算节省时长',
      },
    ],
    defaults: {
      heading: '开启语音后的子开关默认值',
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
    <section className="section section-bordered" id="domain">
      <div className="page-shell">
        <header className="section-header" data-reveal>
          <span className="section-index">02 · 产品能力</span>
          <h2>从候选、整句到语音，每种增强都有明确边界。</h2>
          <p>
            保留 Rime 确定性主链，用双延迟本地语义、三层个人语言画像与可选端上语音，
            降低中文同音消歧、长句与中英混输的选词成本。
          </p>
        </header>

        <div className="workbench" data-reveal>
          <div className="workbench-rail">
            <div aria-label="产品能力" className="workbench-tabs" role="tablist">
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
                  </button>
                )
              })}
            </div>
            <p className="workbench-rail-note">
              <strong>默认原则</strong>
              不用日常输入做跨用户训练，所有本地画像与词库均可检视、导出和清除。
            </p>
          </div>

          <div
            aria-labelledby={`domain-tab-${activePath.id}`}
            className="workbench-panel"
            id="domain-path-panel"
            role="tabpanel"
            tabIndex={0}
          >
            <div className="panel-head">
              <div>
                <span className="panel-kicker">{activePath.kicker}</span>
                <h3>{activePath.title}</h3>
                <p>{activePath.description}</p>
              </div>
              <div className="panel-status">
                <strong>{activePath.status}</strong>
                {activePath.qualifier && <MetricQualifier />}
                <small>{activePath.privacy}</small>
              </div>
            </div>

            <div className="pipeline-grid">
              {activePath.stages.map((stage, index) => (
                <article key={stage.label}>
                  <span className="pipeline-step">{String(index + 1).padStart(2, '0')} · {stage.label}</span>
                  <strong><Rich parts={stage.value} /></strong>
                  <p>{stage.note}</p>
                </article>
              ))}
            </div>

            {activePath.defaults && (
              <div className="defaults-matrix">
                <h4>{activePath.defaults.heading}</h4>
                <div className="defaults-cols">
                  <section className="defaults-group is-on" aria-label="默认开启">
                    <h5>
                      <span className="pill-state is-on">开</span>
                      默认开启
                      <small>均可单独关闭</small>
                    </h5>
                    <ul>
                      {activePath.defaults.on.map((item) => <li key={item}>{item}</li>)}
                    </ul>
                  </section>
                  <section className="defaults-group is-off" aria-label="默认关闭">
                    <h5>
                      <span className="pill-state is-off"><LockIcon size={11} /></span>
                      默认关闭
                      <small>需单独开启</small>
                    </h5>
                    <ul>
                      {activePath.defaults.off.map((item) => <li key={item}>{item}</li>)}
                    </ul>
                  </section>
                </div>
                <p className="defaults-note">{activePath.defaults.note}</p>
              </div>
            )}

            <div className="panel-footnote">
              <Check size={15} />
              <span>{activePath.note}</span>
            </div>
          </div>
        </div>

        <div className="stack-block" data-reveal>
          <div className="stack-header">
            <h3>技术栈与运行边界</h3>
            <span>本地优先，云增强按需开启 · 不用日常输入做跨用户训练</span>
          </div>
          <div className="stack-grid">
            {modelLayers.map((layer) => (
              <article className="stack-card" key={layer.label}>
                <span className="stack-label">{layer.label}</span>
                <strong className="stack-model">{layer.model}</strong>
                <em className="stack-status">{layer.status}</em>
                {layer.qualifier && <MetricQualifier />}
                <p>{layer.detail}</p>
              </article>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}

const privacyModes = [
  {
    id: 'strict',
    label: '严格',
    description: '仅读取当前组合的拼音与候选',
    rangeLabel: '只读当前组合',
    context: 'xian jian cha suo you shi li',
  },
  {
    id: 'standard',
    label: '标准',
    description: '当前应用会话最近上屏的有限文本',
    rangeLabel: '最近上屏 · 当前应用会话',
    context: '新集群已完成镜像拉取，健康检查端口全部正常响应。',
  },
  {
    id: 'smart',
    label: '智能',
    description: '显式开启后读取有限光标前文本',
    rangeLabel: '有限光标前文本 · 显式开启',
    context: '今晚十点切流前先核对配置项，并保留上一版本用于快速回滚。新集群启动后，',
  },
]

function PrivacySection() {
  const [modeId, setModeId] = useState('strict')
  const [cloudEnabled, setCloudEnabled] = useState(false)
  const ids = useMemo(() => privacyModes.map((mode) => mode.id), [])
  const onModeKeyDown = useRovingFocus(ids, modeId, (id) => `context-mode-${id}`, setModeId)
  const activeMode = privacyModes.find((mode) => mode.id === modeId) ?? privacyModes[0]

  return (
    <section className="section section-tinted" id="privacy">
      <div className="page-shell">
        <header className="section-header" data-reveal>
          <span className="section-index">03 · 隐私与进程边界</span>
          <h2>本地优先，云端完全由你决定。</h2>
          <p>
            候选、约束整句与混输默认全部在设备端完成，本地推理 daemon 与语音 worker 均无 INET；
            云增强只有在你配置 API Key 并显式启用后才经独立 broker 运行。安全输入时，全链路自动阻断。
          </p>
        </header>

        <div className="privacy-inspector" data-reveal>
          <div className="privacy-main">
            <div className="mode-column">
              <h3>上下文读取范围</h3>
              <div aria-label="上下文模式" className="mode-list" role="radiogroup">
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
                      <span className="radio-dot" aria-hidden="true" />
                      <span>
                        <strong>{mode.label}</strong>
                        <small>{mode.description}</small>
                      </span>
                    </button>
                  )
                })}
              </div>
            </div>

            <div className="boundary-diagram">
              <div className="diagram-node node-input">
                <span className="node-kicker">{activeMode.rangeLabel}</span>
                <p className="node-context">{activeMode.context}</p>
                <code className="node-pinyin">xian jian cha suo you shi li</code>
              </div>

              <span className="diagram-connector" aria-hidden="true">
                <ArrowRight size={16} />
              </span>

              <div className="diagram-node node-local">
                <span className="node-kicker">本机隔离进程 · UDS / XPC</span>
                <strong>本地语义与语音引擎</strong>
                <p>24M 排序 · MLX 约束整句 · Qwen3-ASR</p>
                <span className="node-tag">进程级禁用 INET · 失败回退 Rime</span>
              </div>

              <div className={`diagram-gate${cloudEnabled ? ' is-open' : ''}`} aria-hidden="true">
                <span className="gate-line" />
                <span className="gate-badge">{cloudEnabled ? 'Broker' : '已阻断'}</span>
                <span className="gate-line" />
              </div>

              <div className={`diagram-node node-cloud${cloudEnabled ? ' is-open' : ''}`}>
                <span className="node-kicker">外部网络边界</span>
                <div className="node-cloud-title">
                  <CloudIcon size={16} />
                  <strong>互联网</strong>
                </div>
                <p aria-live="polite">
                  {cloudEnabled
                    ? '仅独立 cloud broker 可向已配置的固定服务发起请求'
                    : '默认无任何输入内容进入网络路径'}
                </p>
              </div>
            </div>
          </div>

          <div className={`cloud-bar${cloudEnabled ? ' is-on' : ''}`}>
            <div className="cloud-bar-copy">
              <CloudIcon size={18} />
              <div>
                <strong>云端增强（演示开关）</strong>
                <p>默认关闭；配置 API Key 启用后，仅独立 broker 直连固定白名单服务（智谱 glm-5.3-flash）。</p>
              </div>
            </div>
            <div className="cloud-bar-control">
              <span aria-hidden="true">{cloudEnabled ? '已开启' : '已关闭'}</span>
              <button
                aria-checked={cloudEnabled}
                aria-label="云端增强演示开关"
                className="switch"
                onClick={() => setCloudEnabled((value) => !value)}
                role="switch"
                type="button"
              >
                <span aria-hidden="true" />
              </button>
            </div>
          </div>
        </div>

        <div className="commitments-grid" data-reveal>
          <article>
            <span className="commitment-icon" aria-hidden="true"><ShieldIcon /></span>
            <h3>安全输入全链路阻断</h3>
            <p>检测到 macOS Secure Event Input（密码框等）时，立即阻断 AI、云请求、历史写入、语音与自动粘贴并清空上下文。</p>
          </article>
          <article>
            <span className="commitment-icon" aria-hidden="true"><LayersIcon /></span>
            <h3>进程与会话双重隔离</h3>
            <p>不同应用会话互不串读；本地 daemon 与语音 worker 进程级禁用 INET，音频仅驻内存不落盘。</p>
          </article>
          <article>
            <span className="commitment-icon" aria-hidden="true"><SlidersIcon /></span>
            <h3>六页设置与透明默认值</h3>
            <p>
              键盘历史、语音历史与统计、语言画像和领域词库分栏管理，可独立导出与永久清除。
              语音开启后云端热词与 AX 文档回读仍默认关闭，须单独开启。
            </p>
          </article>
        </div>
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
    detail: '键盘主链、双延迟约束整句、段焦点回修、语言画像与领域词库已内部收口。',
  },
  {
    phase: '02',
    title: '质量与盲打度量',
    state: 'active',
    status: '进行中',
    detail: '盲打 first-shot 冻结集口径、决策反馈日志与离线蒸馏三门回归门禁。',
  },
  {
    phase: '03',
    title: '发布与平台验证',
    state: 'pending',
    status: '尚未放行',
    detail: 'Developer ID 签名、公证、清洁机安装、真实宿主、安全输入与语音放行门。',
  },
  {
    phase: '04',
    title: '公开预览',
    state: 'planned',
    status: '以证据推进',
    detail: 'Apple Silicon Mac · macOS 14+，全部放行门通过后开放下载并按真实指标迭代。',
  },
]

const contracts = [
  {
    id: 'space',
    value: 'Space',
    tag: '交互契约',
    lines: ['始终提交 Rime 首选，基础拼音输入肌肉记忆保持不变。'],
  },
  {
    id: 'tab',
    value: 'Tab',
    tag: '交互契约',
    lines: ['显式采纳独立建议位的语义整句、混输或续写联想。'],
  },
  {
    id: 'zero',
    value: '0',
    tag: '安全底线',
    lines: ['零键盘态自动上屏、零默认云请求、零音频文件落盘；语音自动粘贴与润色均可关闭。'],
  },
  {
    id: 'accuracy',
    value: '92.2%',
    tag: '冻结集基线',
    lines: ['MLX 8-bit 零提示词拼音约束整句准确率（p50 115ms，Rime 基线 72.7%）。'],
    qualifier: true,
  },
]

function RoadmapSection() {
  return (
    <section className="section section-bordered" id="roadmap">
      <div className="page-shell">
        <header className="section-header" data-reveal>
          <span className="section-index">04 · 发布路线与硬约束</span>
          <h2>先证明可靠，再交到你的键盘上。</h2>
          <p>
            当前仍是内部基线，暂不提供公开安装包。公开预览前必须完成签名、公证、
            清洁机安装、真实宿主与安全输入验证。
          </p>
        </header>

        <ol aria-label="发布路线" className="roadmap-grid" data-reveal>
          {roadmapSteps.map((step) => (
            <li className={`roadmap-card is-${step.state}`} key={step.phase}>
              <div className="roadmap-card-head">
                <span className="roadmap-phase">{step.phase}</span>
                <span className="roadmap-badge">
                  {step.state === 'pending' && <LockIcon size={11} />}
                  {step.status}
                </span>
              </div>
              <h3>{step.title}</h3>
              <p>{step.detail}</p>
            </li>
          ))}
        </ol>

        <div className="contracts-block" data-reveal>
          <h3>写在交互里的硬约束</h3>
          <div className="contracts-grid">
            {contracts.map((item) => (
              <article key={item.id}>
                <div className="contract-top">
                  <strong>{item.value}</strong>
                  <span>{item.tag}</span>
                </div>
                {item.lines.map((line) => <p key={line}>{line}</p>)}
                {item.qualifier && <MetricQualifier />}
              </article>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}

function FinalCta() {
  return (
    <section className="section cta-section">
      <div className="page-shell">
        <div className="cta-box" data-reveal>
          <div className="cta-copy">
            <span className="section-index">Apache-2.0 · 开源代码与文档</span>
            <h2>中文输入的确定性，加上语义理解的新可能。</h2>
            <p>Rime 始终兜底，AI 始终建议。源码、评测脚本与完整设计文档均公开在 GitHub 仓库中。</p>
          </div>
          <div className="cta-actions">
            <a className="btn btn-primary" href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
              在 GitHub 查看源码
              <ArrowUpRight size={15} />
            </a>
            <button className="btn btn-secondary" onClick={() => scrollToSection('top')} type="button">
              回到顶部演示
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
        <div className="footer-brand">
          <a className="brand" href="#top" aria-label="RimeAI 首页">
            <span className="brand-badge" aria-hidden="true">
              <BrandMark size={15} />
            </span>
            <span>RimeAI</span>
          </a>
          <span className="footer-note">Apple Silicon Mac · macOS 14+ · Apache-2.0 · 内部基线，尚未公开发布</span>
        </div>

        <nav aria-label="页脚导航" className="footer-nav">
          <a href="#how">工作方式</a>
          <a href="#domain">产品能力</a>
          <a href="#privacy">隐私边界</a>
          <a href="#roadmap">发布路线</a>
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

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-visible')
            observer.unobserve(entry.target)
          }
        })
      },
      { rootMargin: '0px 0px -48px 0px', threshold: 0 },
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
