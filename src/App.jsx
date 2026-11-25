import { useEffect, useMemo, useState } from 'react'

const GITHUB_URL = 'https://github.com/wuxiao/RimeAI'

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

function scrollToSection(id) {
  document.querySelector(`#${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
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

      <a className="header-action" href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
        GitHub 源码
        <ArrowRight />
      </a>
    </header>
  )
}

function EditorDemo() {
  const [accepted, setAccepted] = useState(false)

  return (
    <div className="editor-shell" aria-label="RimeAI 双通路候选交互演示">
      <div className="editor-titlebar">
        <div className="traffic-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div className="editor-title">PostgreSQL 技术写作.md <span>— 已编辑</span></div>
        <button
          aria-label="重新演示"
          className="reset-demo"
          onClick={() => setAccepted(false)}
          type="button"
        >
          <svg aria-hidden="true" fill="none" viewBox="0 0 24 24">
            <path d="M19 8V4m0 0h-4m4 0-3 3a7 7 0 1 0 1.5 7.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
          </svg>
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

      <div className="editor-document">
        <h2>理解 PostgreSQL 的 MVCC</h2>
        <p>PostgreSQL 使用多版本并发控制来提供高并发下的一致性读。</p>
        <p>每个事务看到的是启动时刻的数据库快照，读操作不会阻塞写操作。</p>
        <p>在实现上，PostgreSQL 通过元组版本字段判断数据可见性。</p>
        <p>合理的索引设计与 VACUUM 策略，是保持系统健康的关键。</p>
        <p className="editor-lead">因此，我们需要先明确数据库在服务中的角色。</p>

        <div className={`composition ${accepted ? 'is-accepted' : ''}`}>
          <span>这个服务使用 PostgreSQL 作为</span>
          {accepted ? (
            <strong>主数据库。</strong>
          ) : (
            <span className="pinyin">zhu shu ju ku<span className="caret" /></span>
          )}
        </div>

        <div className={`candidate-popover ${accepted ? 'is-accepted' : ''}`}>
          <div className="candidate-row rime-row">
            <div className="candidate-items">
              <span><b>1</b> 主数据库</span>
              <span><b>2</b> 住数据库</span>
              <span><b>3</b> 主数据哭</span>
              <span><b>4</b> 主数据库中</span>
            </div>
            <em>Rime 稳定候选</em>
          </div>

          <button
            className="semantic-row"
            disabled={accepted}
            onClick={() => setAccepted(true)}
            type="button"
          >
            <span className="semantic-main">
              {accepted ? <Check /> : <Spark />}
              <span>{accepted ? '已上屏：主数据库' : '主数据库'}</span>
            </span>
            <span className="semantic-action">
              {accepted ? '由你确认' : 'RimeAI 语义建议'}
              {!accepted && <ArrowRight size={16} />}
            </span>
          </button>
        </div>
      </div>

      <div className="editor-status" aria-hidden="true">
        <span>字数：1,024</span>
        <span>行数：42</span>
        <span>100%</span>
        <span>UTF-8</span>
        <span>Markdown</span>
      </div>
    </div>
  )
}

function Hero() {
  return (
    <section className="hero" id="top">
      <Header />
      <div className="hero-content page-shell">
        <div className="hero-copy" data-reveal>
          <h1 aria-label="让输入更懂上下文，让选择始终属于你。">
            <span aria-hidden="true" className="hero-title-desktop">
              <span>让输入更懂上下文，</span>
              <span>让选择始终属于你。</span>
            </span>
            <span aria-hidden="true" className="hero-title-mobile">
              <span>让输入更懂</span>
              <span>上下文，让选择</span>
              <span>始终属于你。</span>
            </span>
          </h1>
          <p>
            RimeAI 在 Rime 的稳定候选之上，加入本地语义排序、整句建议与中英混输。
            AI 只在独立建议位出现，由你主动采纳，绝不自动上屏。
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
            <svg aria-hidden="true" fill="none" viewBox="0 0 24 24">
              <path d="M5 6.5h14v10H5zM3 19h18" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
            </svg>
            <span>Apple Silicon Mac · macOS 14+ · 内部基线，尚未公开发布</span>
          </div>
        </div>
        <div className="hero-demo" data-reveal>
          <EditorDemo />
        </div>
      </div>
    </section>
  )
}

const processSteps = [
  {
    number: '01',
    title: '即时候选',
    detail: 'Rime 同步负责拼音切分、词典与候选兜底，不等待 AI。',
  },
  {
    number: '02',
    title: '本地判断',
    detail: '24M 排序器融合 n-gram，在设备端理解上下文。',
  },
  {
    number: '03',
    title: '主动上屏',
    detail: 'Space 提交 Rime 首选，Tab 采纳 AI 建议。',
  },
]

function WorkflowSection() {
  const [exampleAccepted, setExampleAccepted] = useState(false)

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
              <div className="step-number">{step.number}</div>
              <div className="step-marker" aria-hidden="true" />
              <h3>{step.title}</h3>
              <p>{step.detail}</p>
            </article>
          ))}
          <span className="delay-note" aria-hidden="true">本地异步建议</span>
        </div>

        <div className="mixed-input" data-reveal>
          <div className="mixed-copy">
            <h3>中文、API 与代码，<br />可以在同一句里自然共存。</h3>
            <span className="accent-stroke" aria-hidden="true" />
            <p>英文标识符、命令、路径与 URL 保持原样。</p>
          </div>

          <div className="technical-editor">
            <div className="tech-toolbar" aria-hidden="true">
              <span>正文</span>
              <span>PingFang SC</span>
              <span>16</span>
              <b>B</b>
              <i>I</i>
              <span>&lt;/&gt;</span>
            </div>
            <p className="tech-sentence">
              这个 <code>API</code> 需要增加 <code>timeout</code> 配置，并更新{' '}
              <code>feature/local-ranker</code> 分支。
            </p>
            <div className="mini-candidates">
              <div className="mini-rime">
                <span>1 分支</span>
                <span>2 分治</span>
                <span>3 分值</span>
                <em>Rime 稳定候选</em>
              </div>
              <button onClick={() => setExampleAccepted((value) => !value)} type="button">
                {exampleAccepted ? <Check /> : <Spark />}
                <span>{exampleAccepted ? '已选择：feature/local-ranker 分支' : '语义建议：feature/local-ranker 分支'}</span>
                <small>{exampleAccepted ? '已确认' : '点击选择'}</small>
              </button>
            </div>
          </div>
        </div>
      </div>

      <div className="system-strip" aria-hidden="true">
        <div className="system-strip-inner">
          <span className="strip-brand"><BrandMark size={26} /></span>
          <span>rime stable · instant candidates</span>
          <i />
          <span>24M ranker · on-device semantics</span>
          <i />
          <span>space for rime · tab for ai</span>
          <Check size={16} />
        </div>
      </div>
    </section>
  )
}

const domainPaths = [
  {
    id: 'sentence',
    tab: '整句建议',
    kicker: '本地语义路径',
    title: '一句拼音，得到一条完整、可确认的建议。',
    description: '本地约束解码器按拼音生成整句，可处理常见错音与中英混排；结构不合法就弃权。',
    status: '拼音约束 · 失败回退 Rime',
    privacy: '本地推理 · 不自动上屏',
    note: '不展示半句话 · 低置信度或结构校验失败时保留 Rime',
    stages: [
      { label: '输入', value: '完整拼音与有限上下文', note: '支持标点、中英文与常见错音' },
      { label: '处理', value: '本地拼音约束解码', note: '完整覆盖输入，不开放式续写' },
      { label: '确认', value: 'Tab 采纳整句建议', note: 'Space 仍提交 Rime 首选' },
    ],
  },
  {
    id: 'mixed',
    tab: '中英混输',
    kicker: '无空格输入',
    title: 'API、timeout 与中文，不必手动切换。',
    description: '连续大写英文作为强边界，小写技术词采用保守识别；完整可解析的拼音优先留给 Rime。',
    status: '保守分段 · 原样保留',
    privacy: '标识符不被擅自改写',
    note: '英文大小写、标识符、路径与 URL 保持原样',
    stages: [
      { label: '输入', value: 'zhegeAPIxuyaotimeout', note: '无需用 Space 充当语言分隔符' },
      { label: '分段', value: '中文 + API + timeout', note: '大写强边界，小写保守识别' },
      { label: '确认', value: '这个 API 需要 timeout', note: '独立建议位展示，Tab 明确采用' },
    ],
  },
  {
    id: 'profile',
    tab: '语言画像',
    kicker: '个人化路径',
    title: '越用越像你，也能看清它学到了什么。',
    description: '成功上屏的文本可固化为短语、用户语言模型与风格画像；每层都可查看、导出与清除。',
    status: '本机固化 · 可选云压缩',
    privacy: '不跨用户共享画像',
    note: '历史与画像分别管理 · 云压缩可独立关闭',
    stages: [
      { label: '学习', value: '你已确认的上屏文本', note: '安全输入不写入历史' },
      { label: '固化', value: '短语 · 用户 LM · 风格', note: '空闲时提炼为三层语言画像' },
      { label: '控制', value: '可见、可编辑、可清除', note: '支持锁定、导出与独立管理' },
    ],
  },
]

const modelLayers = [
  {
    label: '候选排序',
    model: '24M · Local',
    status: '内部基线已验证',
    detail: '本地神经排序器融合 n-gram，对 Rime Top-10 进行上下文评分。',
  },
  {
    label: '整句解码',
    model: 'MLX · 8-bit',
    status: '可选本地能力',
    detail: '拼音约束 beam decoder 提供完整建议；失败或超时始终回退 Rime。',
  },
  {
    label: '云端增强',
    model: 'glm-5.3-flash',
    status: '默认关闭',
    detail: '独立 broker 仅在用户配置后启用；结果经结构校验，仍需主动确认。',
  },
]

function DomainSection() {
  const [pathId, setPathId] = useState('sentence')
  const activePath = useMemo(
    () => domainPaths.find((path) => path.id === pathId) ?? domainPaths[0],
    [pathId],
  )

  return (
    <section className="domain section-light" id="domain">
      <div className="page-shell">
        <header className="section-heading domain-heading" data-reveal>
          <span className="section-kicker">产品能力</span>
          <h2>从候选到整句，<br className="mobile-break" />更懂你的表达。</h2>
          <p>
            为中文技术写作优化：保留 Rime 的确定性，
            再用本地语义减少翻页、选词和中英文切换。
          </p>
        </header>

        <div className="domain-workbench" data-reveal>
          <div className="domain-paths" role="tablist" aria-label="领域能力路径">
            <div className="path-intro">
              <small>选择能力</small>
              <strong>每种增强，都有明确边界。</strong>
            </div>
            {domainPaths.map((path) => (
              <button
                aria-controls="domain-path-panel"
                aria-selected={pathId === path.id}
                className={pathId === path.id ? 'is-active' : ''}
                key={path.id}
                onClick={() => setPathId(path.id)}
                role="tab"
                type="button"
              >
                <span>{path.tab}</span>
                <small>{path.kicker}</small>
                <i aria-hidden="true"><ArrowRight size={16} /></i>
              </button>
            ))}

            <div className="domain-rule">
              <Spark size={18} />
              <p>
                <strong>默认规则</strong>
                不用日常输入做跨用户训练，个人画像由你控制。
              </p>
            </div>
          </div>

          <div
            aria-live="polite"
            className={`domain-path-panel is-${activePath.id}`}
            id="domain-path-panel"
            role="tabpanel"
          >
            <div className="path-panel-heading">
              <div>
                <span>{activePath.kicker}</span>
                <h3>{activePath.title}</h3>
                <p>{activePath.description}</p>
              </div>
              <div className="path-status">
                <strong>{activePath.status}</strong>
                <small>{activePath.privacy}</small>
              </div>
            </div>

            <div className="data-pipeline">
              {activePath.stages.map((stage, index) => (
                <article key={stage.label}>
                  <span>{String(index + 1).padStart(2, '0')} · {stage.label}</span>
                  <strong>{stage.value}</strong>
                  <small>{stage.note}</small>
                </article>
              ))}
            </div>

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
      <strong>本地语义引擎</strong>
      <span>24M 排序器 · n-gram · 约束解码</span>
      <span>不确定时保留 Rime</span>
    </div>
  )
}

function PrivacySection() {
  const [modeId, setModeId] = useState('strict')
  const [cloudEnabled, setCloudEnabled] = useState(false)
  const activeMode = useMemo(
    () => privacyModes.find((mode) => mode.id === modeId) ?? privacyModes[0],
    [modeId],
  )

  return (
    <section className="privacy section-dark" id="privacy">
      <div className="page-shell">
        <header className="section-heading privacy-heading" data-reveal>
          <h2>本地优先，<br className="mobile-break" />云端由你决定。</h2>
          <p>
            候选、整句与混输默认在设备端完成。云增强只有在你配置并启用后才运行；
            安全输入时，自动阻断 AI、上下文、历史与云请求。
          </p>
        </header>

        <div className="privacy-console" data-reveal>
          <div className="mode-panel">
            <h3>上下文由你决定</h3>
            <div className="mode-options" role="radiogroup" aria-label="上下文模式">
              {privacyModes.map((mode) => (
                <button
                  aria-checked={modeId === mode.id}
                  className={modeId === mode.id ? 'is-active' : ''}
                  key={mode.id}
                  onClick={() => setModeId(mode.id)}
                  role="radio"
                  type="button"
                >
                  <span className="mode-icon"><ContextIcon type={mode.id} /></span>
                  <span>
                    <strong>{mode.label}</strong>
                    <small>{mode.description}</small>
                  </span>
                  <i aria-hidden="true" />
                </button>
              ))}
            </div>
          </div>

          <div className="boundary-panel" aria-live="polite">
            <div className="context-preview">
              <small>{activeMode.rangeLabel}</small>
              <p>{activeMode.context}</p>
              <div className="pinyin-preview">zhu shu ju ku<span className="caret" /></div>
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
              <span>{cloudEnabled ? '仅独立 broker 可发起已配置请求' : '默认无输入内容进入网络路径'}</span>
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
            aria-label={cloudEnabled ? '关闭云端增强演示' : '开启云端增强演示'}
            aria-pressed={cloudEnabled}
            className="toggle"
            onClick={() => setCloudEnabled((value) => !value)}
            type="button"
          >
            <span />
          </button>
          <em>{cloudEnabled ? '已开启' : '已关闭'}</em>
        </div>

        <div className="privacy-commitments">
          <article data-reveal>
            <CommitmentIcon type="secure" />
            <div>
              <h3>安全输入自动停用</h3>
              <p>检测到系统安全输入时，不创建 AI 请求并清空相关上下文。</p>
            </div>
          </article>
          <article data-reveal>
            <CommitmentIcon type="isolation" />
            <div>
              <h3>应用之间上下文隔离</h3>
              <p>不同应用与会话的短期上下文互不读取，切换应用即失效。</p>
            </div>
          </article>
          <article data-reveal>
            <CommitmentIcon type="clear" />
            <div>
              <h3>数据边界清晰可见</h3>
              <p>历史与语言画像可分别查看、导出和永久清除，凭据不进入诊断。</p>
            </div>
          </article>
        </div>

        <p className="privacy-qualifier">
          页面开关仅用于演示 · 本地 daemon 无 INET，云联网只发生在独立、显式启用的 broker
        </p>
      </div>
    </section>
  )
}

const roadmapSteps = [
  {
    phase: '01',
    title: '内部基线',
    status: '当前阶段',
    detail: 'macOS 核心输入与本地语义链路',
  },
  {
    phase: '02',
    title: '发布验证',
    status: '下一阶段',
    detail: '签名、公证、清洁机与真实宿主',
  },
  {
    phase: '03',
    title: '公开预览',
    status: '尚未放行',
    detail: 'Apple Silicon Mac · macOS 14+',
  },
  {
    phase: '04',
    title: '持续优化',
    status: '以证据推进',
    detail: '冻结集、真实指标与用户反馈',
  },
]

const targets = [
  { value: 'Space', label: '提交 Rime 首选，基础语义不变' },
  { value: 'Tab', label: '显式采纳当前 AI 建议' },
  { value: '0', label: '默认云端请求与自动上屏' },
  { value: '24M', label: '设备端专用候选排序器' },
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

        <div className="roadmap-line" data-reveal>
          {roadmapSteps.map((step, index) => (
            <article className={index === 0 ? 'is-current' : ''} key={step.phase}>
              <div className="roadmap-title">
                <span>{step.phase}</span>
                <h3>{step.title}</h3>
              </div>
              <div className="roadmap-track"><i /></div>
              <p><strong>{step.status}</strong> · {step.detail}</p>
            </article>
          ))}
        </div>

        <div className="targets-heading" data-reveal>
          <h3>写在交互里的硬约束</h3>
        </div>
        <div className="targets-grid">
          {targets.map((target) => (
            <article data-reveal key={target.label}>
              <div>
                <strong>{target.value}</strong>
                <em>产品合同</em>
              </div>
              <p>{target.label}</p>
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
      <Footer />
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
          <svg aria-hidden="true" fill="none" viewBox="0 0 24 24">
            <path d="M5 6.5h14v10H5zM3 19h18" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
          </svg>
          Apple Silicon Mac · macOS 14+ · 尚未公开发布
        </div>
        <nav aria-label="页脚导航">
          <a href="#how">工作方式</a>
          <span>/</span>
          <a href="#domain">产品能力</a>
          <span>/</span>
          <a href="#privacy">隐私</a>
          <span>/</span>
          <a href="#roadmap">发布路线</a>
          <span>/</span>
          <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">GitHub · wuxiao/RimeAI</a>
        </nav>
      </div>
    </footer>
  )
}

function App() {
  useEffect(() => {
    const elements = document.querySelectorAll('[data-reveal]')
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches

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
      { threshold: 0.12 },
    )

    elements.forEach((element) => observer.observe(element))
    return () => observer.disconnect()
  }, [])

  return (
    <>
      <a className="skip-link" href="#how">跳到主要内容</a>
      <main>
        <Hero />
        <WorkflowSection />
        <DomainSection />
        <PrivacySection />
        <RoadmapSection />
        <FinalCta />
      </main>
    </>
  )
}

export default App
