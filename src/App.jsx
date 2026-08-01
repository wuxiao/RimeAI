import { useEffect, useMemo, useState } from 'react'

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
  document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
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
        <a href="#domain">领域能力</a>
        <span aria-hidden="true">/</span>
        <a href="#privacy">隐私</a>
        <span aria-hidden="true">/</span>
        <a href="#roadmap">路线图</a>
      </nav>

      <button className="header-action" onClick={() => scrollToSection('domain')} type="button">
        查看模型与训练
        <ArrowRight />
      </button>
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
          <h1 aria-label="让输入更懂上下文，内容仍只在本机。">
            <span aria-hidden="true" className="hero-title-desktop">
              <span>让输入更懂上下文，</span>
              <span>内容仍只在本机。</span>
            </span>
            <span aria-hidden="true" className="hero-title-mobile">
              <span>让输入更懂</span>
              <span>上下文，内容</span>
              <span>仍只在本机。</span>
            </span>
          </h1>
          <p>
            RimeAI 在 Rime 的稳定候选之上，加入设备端专用候选排序。
            可选整句模型只在需要时出现，最终仍由你决定是否上屏。
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
            <span>P0 评测工具已实现 · macOS 输入法尚未发布</span>
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
    detail: 'Rime 负责切分、词典与稳定候选。',
  },
  {
    number: '02',
    title: '本地判断',
    detail: '停顿后，专用排序器在本机对 Top-10 批量评分。',
  },
  {
    number: '03',
    title: '主动上屏',
    detail: 'AI 建议独立显示，不换位，也不自动输入。',
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
          <span className="delay-note" aria-hidden="true">80–120ms</span>
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
          <span>specialized reranker · target &lt; 50ms</span>
          <i />
          <span>user choice · on demand</span>
          <Check size={16} />
        </div>
      </div>
    </section>
  )
}

const domainPaths = [
  {
    id: 'dictionary',
    tab: '专业词库',
    kicker: '本地路径',
    title: '12,480 个术语，导入后直接参与候选生成。',
    description: '产品名、客户名、类名与固定短语进入 Rime 领域词典，不需要等待模型学习。',
    status: '无需训练 · 立即生效',
    privacy: '0 条语料上传',
    stages: [
      { label: '来源', value: 'software_terms.yaml', note: '用户主动选择的词条文件' },
      { label: '处理', value: 'Rime 领域词典', note: '本地校验、去重与编译' },
      { label: '结果', value: '下一次组合生效', note: '继续保留纯 Rime 兜底' },
    ],
  },
  {
    id: 'training',
    tab: '授权语料',
    kicker: '可选训练路径',
    title: '专业句子用于训练“如何排序”，不是上传日常输入。',
    description: '系统用固定 Rime 配置生成拼音、Top-10 候选与同音难例，再训练领域排序适配器。',
    status: '逐批授权 · 与输入链路分离',
    privacy: '日常按键不采集',
    stages: [
      { label: '来源', value: '38,200 条授权句子', note: '先检查处理权与敏感信息' },
      { label: '训练', value: '上下文 + 拼音 + 候选', note: '学习正确候选编号与置信度' },
      { label: '制品', value: '签名领域模型', note: '合并、量化、校验后下载' },
    ],
  },
]

const modelLayers = [
  {
    label: '实时排序层',
    model: 'GTE · 306M',
    status: 'P0 领先基线',
    detail: '批量评分 Rime Top-10；当前优先验证质量与原生部署。',
  },
  {
    label: '生产目标层',
    model: '80–150M',
    status: '待蒸馏验证',
    detail: '将教师模型的领域判断压缩到拼音感知专用排序器。',
  },
  {
    label: '整句生成层',
    model: '350–500M',
    status: 'P1 可选能力',
    detail: '只提供一条明确标识的整句建议，不参与同步主链路。',
  },
]

function DomainSection() {
  const [pathId, setPathId] = useState('dictionary')
  const [trainingAuthorized, setTrainingAuthorized] = useState(false)
  const activePath = useMemo(
    () => domainPaths.find((path) => path.id === pathId) ?? domainPaths[0],
    [pathId],
  )

  return (
    <section className="domain section-light" id="domain">
      <div className="page-shell">
        <header className="section-heading domain-heading" data-reveal>
          <span className="section-kicker">领域能力</span>
          <h2>专业能力，不等于<br className="mobile-break" />上传你的输入。</h2>
          <p>
            词条优先交给 Rime；只有你主动选择并授权的句子文件，
            才能进入与输入法完全分离的训练流程。
          </p>
        </header>

        <div className="domain-workbench" data-reveal>
          <div className="domain-paths" role="tablist" aria-label="领域能力路径">
            <div className="path-intro">
              <small>选择数据类型</small>
              <strong>不同数据，走不同路径。</strong>
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
                不被动收集按键、组合串或完整文档。
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

            {activePath.id === 'training' ? (
              <button
                aria-pressed={trainingAuthorized}
                className={`training-consent ${trainingAuthorized ? 'is-authorized' : ''}`}
                onClick={() => setTrainingAuthorized((value) => !value)}
                type="button"
              >
                <span className="consent-toggle" aria-hidden="true"><i /></span>
                <span>
                  <strong>{trainingAuthorized ? '本批文件已授权（演示）' : '本批文件尚未授权（演示）'}</strong>
                  <small>
                    {trainingAuthorized
                      ? '可以进入敏感信息检查；授权不覆盖之后新增的文件。'
                      : '训练入口保持锁定，不影响本地词库和日常输入。'}
                  </small>
                </span>
              </button>
            ) : (
              <div className="local-only-note">
                <Check size={18} />
                <span><strong>仅本地处理</strong> · 不创建训练任务，也不改变 Offline Lock。</span>
              </div>
            )}
          </div>
        </div>

        <div className="model-stack" data-reveal>
          <div className="model-stack-heading">
            <small>当前模型路线</small>
            <h3>一个实时排序器，<br />一个可选生成器。</h3>
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
      <strong>专用候选排序器</strong>
      <span>GTE 306M · P0 评测候选</span>
      <span>低置信度不展示</span>
    </div>
  )
}

function PrivacySection() {
  const [modeId, setModeId] = useState('strict')
  const [offlineLock, setOfflineLock] = useState(true)
  const activeMode = useMemo(
    () => privacyModes.find((mode) => mode.id === modeId) ?? privacyModes[0],
    [modeId],
  )

  return (
    <section className="privacy section-dark" id="privacy">
      <div className="page-shell">
        <header className="section-heading privacy-heading" data-reveal>
          <h2>你的输入，<br className="mobile-break" />不需要离开设备。</h2>
          <p>
            组合串、上下文与候选选择默认不上传，也不写入原始文本日志。
            只有训练中心里逐批授权的文件才可能离开设备；你也可以始终只用本地词库。
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
            <span className="flow-line blocked" aria-hidden="true">
              <i />
              <b>×</b>
            </span>

            <div className="network-boundary">
              <svg aria-hidden="true" fill="none" viewBox="0 0 64 48">
                <path d="M17 39h32a10 10 0 0 0 1-19.9A16 16 0 0 0 19.7 15 12 12 0 0 0 17 39Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" />
              </svg>
              <strong>互联网</strong>
              <span>输入内容不进入网络路径</span>
            </div>
          </div>
        </div>

        <div className={`offline-lock ${offlineLock ? 'is-on' : ''}`} data-reveal>
          <div className="lock-symbol" aria-hidden="true">
            <svg fill="none" viewBox="0 0 28 28">
              <path d="m15.5 3-7 11h6l-2 11 7-13h-6l2-9Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.6" />
            </svg>
          </div>
          <div className="lock-title">
            <strong>Offline Lock</strong>
            <p>开启后，输入法与推理服务不主动联网，模型仅从本地文件导入。</p>
          </div>
          <button
            aria-label={offlineLock ? '关闭 Offline Lock 演示' : '开启 Offline Lock 演示'}
            aria-pressed={offlineLock}
            className="toggle"
            onClick={() => setOfflineLock((value) => !value)}
            type="button"
          >
            <span />
          </button>
          <em>{offlineLock ? '已开启' : '已关闭'}</em>
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
              <h3>一键清除本地数据</h3>
              <p>短期上下文、RimeAI 数据与可选模型缓存都可独立清除。</p>
            </div>
          </article>
        </div>

        <p className="privacy-qualifier">
          网络隔离、清除与安全输入均需通过自动化测试和人工验证
        </p>
      </div>
    </section>
  )
}

const roadmapSteps = [
  {
    phase: 'P0',
    title: '离线效果验证',
    status: '当前阶段',
    detail: '比较原生 Rime、规则重排与本地模型',
  },
  {
    phase: 'P1',
    title: 'macOS 技术原型',
    status: '通过质量与性能门槛后',
    detail: '接入稳定的双通路候选',
  },
  {
    phase: 'P2',
    title: '开发者预览',
    status: '通过隐私与分发门槛后',
    detail: '提供控制中心、Offline Lock 与签名安装',
  },
  {
    phase: 'P3',
    title: '领域能力',
    status: '通过独立数据治理后',
    detail: '本地词库与可选授权训练',
  },
]

const targets = [
  { value: '+ 5%', label: 'conditional Top-1 相对提升' },
  { value: '< 50ms', label: '专用重排器 P50 目标' },
  { value: '< 400ms', label: 'AI 建议 P95 硬上限' },
  { value: '0 次', label: '默认输入内容外传' },
]

function RoadmapSection() {
  return (
    <section className="roadmap section-light" id="roadmap">
      <div className="page-shell">
        <header className="section-heading roadmap-heading" data-reveal>
          <h2>从可验证的效果<br className="mobile-break" />开始。</h2>
          <p>
            306M 是当前评测起点，不是最终答案。准确率、延迟、稳定性与隐私边界，
            必须在同一数据集、同一 Rime 配置和同一硬件上证明。
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
          <h3>开发目标，不是宣传数字</h3>
        </div>
        <div className="targets-grid">
          {targets.map((target) => (
            <article data-reveal key={target.label}>
              <div>
                <strong>{target.value}</strong>
                <em>验证目标</em>
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
          <h2>Rime 的确定性，叠加本地语义的判断力。</h2>
          <p>词库留在 Rime，语义模型只做它擅长的判断；先验证，再交到你的键盘上。</p>
          <div>
            <button className="button button-primary" onClick={() => scrollToSection('top')} type="button">
              回到产品演示
              <ArrowRight />
            </button>
            <button className="text-link" onClick={() => scrollToSection('privacy')} type="button">
              查看隐私边界
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
          P0 评测工具已实现 · 输入法尚未发布
        </div>
        <nav aria-label="页脚导航">
          <a href="#how">工作方式</a>
          <span>/</span>
          <a href="#domain">领域能力</a>
          <span>/</span>
          <a href="#privacy">隐私</a>
          <span>/</span>
          <a href="#roadmap">路线图</a>
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
