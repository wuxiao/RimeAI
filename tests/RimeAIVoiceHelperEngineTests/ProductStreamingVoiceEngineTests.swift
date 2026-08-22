import Foundation
import Testing
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine

@Suite(.serialized)
struct ProductStreamingVoiceEngineTests {
    @Test
    func initializationRequiresTheExactProductStreamingAudioContract() throws {
        let dependencies = TestDependencies()
        let engine = try ProductStreamingVoiceEngine(
            descriptor: makeProductDescriptor(),
            sourceFactory: dependencies.sourceFactory,
            recognizerDriver: dependencies.driver,
            hotwordProvider: dependencies.hotwordProvider
        )

        #expect(engine.descriptor == makeProductDescriptor())

        let invalid = [
            makeProductDescriptor(qualification: .probeOnly),
            makeProductDescriptor(networkPolicy: .cloudASROnly),
            makeProductDescriptor(capabilities: [.localASR]),
            makeProductDescriptor(audioFormat: .fixedLinearPCM(
                sampleRateHertz: 48_000,
                channelCount: 1,
                bitsPerChannel: 32
            )),
            makeProductDescriptor(maximumAlternatives: 2),
        ]
        for descriptor in invalid {
            #expect(throws: ProductStreamingVoiceEngineError.invalidDescriptor) {
                try ProductStreamingVoiceEngine(
                    descriptor: descriptor,
                    sourceFactory: dependencies.sourceFactory,
                    recognizerDriver: dependencies.driver,
                    hotwordProvider: dependencies.hotwordProvider
                )
            }
        }

        dependencies.driver.artifactGeneration = UUID()
        #expect(
            throws: ProductStreamingVoiceEngineError
                .artifactGenerationMismatch
        ) {
            try ProductStreamingVoiceEngine(
                descriptor: makeProductDescriptor(),
                sourceFactory: dependencies.sourceFactory,
                recognizerDriver: dependencies.driver,
                hotwordProvider: dependencies.hotwordProvider
            )
        }
    }

    @Test
    func secondStartWhileSessionIsActiveFailsWithRetryableOverload() throws {
        let dependencies = TestDependencies()
        let engine = try dependencies.makeEngine()
        let first = TestEventCollector()
        let second = TestEventCollector()

        engine.start(makeRequest(id: "first"), events: first.append)
        engine.start(makeRequest(id: "second"), events: second.append)

        #expect(first.events.isEmpty)
        #expect(second.events == [.failed(.asrOverload, retryable: true)])
        #expect(dependencies.sourceFactory.makeCount == 1)
        #expect(dependencies.sourceFactory.sources.first?.startCount == 1)
        #expect(dependencies.driver.resetHotwordBatches.count == 1)

        engine.cancel(requestID: "first")
    }

    @Test
    func partialsAreDeduplicatedAndEndpointsBecomeStableWithoutFinalizing()
        throws
    {
        let dependencies = TestDependencies()
        dependencies.driver.enqueueAcceptUpdates([
            .init(text: " 你\n", isEndpoint: false),
            .init(text: "你", isEndpoint: false),
            .init(text: "你好", isEndpoint: true),
            .init(text: " 世界 ", isEndpoint: false),
        ])
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "segments"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        for marker in 1...4 {
            source.emit(validFrame(marker: Float(marker)))
        }

        #expect(waitUntil { collector.events.count == 3 })
        #expect(collector.events == [
            .partial(stableText: "", partialText: "你", confidence: 0),
            .partial(stableText: "你好", partialText: "", confidence: 0),
            .partial(
                stableText: "你好",
                partialText: "世界",
                confidence: 0
            ),
        ])
        #expect(dependencies.driver.resetHotwordBatches.count == 1)
        #expect(dependencies.driver.endpointResetCount == 1)

        engine.cancel(requestID: "segments")
    }

    @Test
    func stopSynchronouslyFlushesSourceThenDrainsAndFinalizesExactlyOnce()
        throws
    {
        let dependencies = TestDependencies()
        dependencies.driver.finishUpdate = .init(
            text: " 完\r\n成 ",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "drain"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame(marker: 1))
        source.emit(validFrame(marker: 2))
        source.onStop = {
            source.emit(validFrame(marker: 3))
        }

        engine.stop(requestID: "drain")

        #expect(source.stopCount == 1)
        #expect(waitUntil {
            collector.events.contains(.finished(
                text: "完 成",
                confidence: 0,
                polishApplied: false
            ))
        })
        #expect(dependencies.driver.acceptedSamples.map { $0[0] }
            == [1, 2, 3])
        #expect(dependencies.driver.calls.suffix(2) == ["finish", "cancel"])
        #expect(collector.events.filter {
            if case .finished = $0 { return true }
            return false
        }.count == 1)

        engine.stop(requestID: "drain")
        Thread.sleep(forTimeInterval: 0.01)
        #expect(source.stopCount == 1)
        #expect(collector.events.filter {
            if case .finished = $0 { return true }
            return false
        }.count == 1)
    }

    @Test
    func emptyStoppedSessionFailsWithRetryableTimeout() throws {
        let dependencies = TestDependencies()
        dependencies.driver.enqueueAcceptUpdates([
            .init(text: " \r\n ", isEndpoint: true),
        ])
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "empty"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame())
        #expect(waitUntil {
            dependencies.driver.endpointResetCount == 1
        })
        #expect(collector.events.isEmpty)
        engine.stop(requestID: "empty")

        #expect(waitUntil {
            collector.events == [.failed(.asrTimeout, retryable: true)]
        })
        #expect(source.stopCount == 1)
        #expect(source.cancelCount == 1)
        #expect(waitUntil { dependencies.driver.cancelCount == 1 })
    }

    @Test
    func cancelInvalidatesSessionBeforeDroppingLateFramesAndFailures() throws {
        let dependencies = TestDependencies()
        dependencies.driver.enqueueAcceptUpdates([
            .init(text: "迟到", isEndpoint: false),
        ])
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "cancel"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        engine.cancel(requestID: "cancel")
        source.emit(validFrame(marker: 7))
        source.fail(.init(code: .micUnavailable, retryable: false))

        Thread.sleep(forTimeInterval: 0.01)
        #expect(collector.events.isEmpty)
        #expect(source.stopCount == 0)
        #expect(source.cancelCount == 1)
        #expect(waitUntil { dependencies.driver.cancelCount == 1 })
        #expect(dependencies.driver.acceptedSamples.isEmpty)
    }

    @Test
    func sourceFailureIsForwardedAndCancelsTheWholeSession() throws {
        let dependencies = TestDependencies()
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "source-failure"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.fail(.init(code: .micUnavailable, retryable: false))
        source.emit(validFrame())

        #expect(waitUntil {
            collector.events == [.failed(.micUnavailable, retryable: false)]
        })
        #expect(source.cancelCount == 1)
        #expect(dependencies.driver.acceptedSamples.isEmpty)
        #expect(waitUntil { dependencies.driver.cancelCount == 1 })
    }

    @Test
    func sourceConstructionAndStartErrorsMapToRetryableMicUnavailable() throws {
        let construction = TestDependencies()
        construction.sourceFactory.makeError = TestFailure.expected
        let constructionEngine = try construction.makeEngine()
        let constructionEvents = TestEventCollector()
        constructionEngine.start(
            makeRequest(id: "source-construction"),
            events: constructionEvents.append
        )
        #expect(constructionEvents.events == [
            .failed(.micUnavailable, retryable: true),
        ])

        let startup = TestDependencies()
        startup.sourceFactory.nextSourceStartError = TestFailure.expected
        let startupEngine = try startup.makeEngine()
        let startupEvents = TestEventCollector()
        startupEngine.start(
            makeRequest(id: "source-start"),
            events: startupEvents.append
        )
        #expect(startupEvents.events == [
            .failed(.micUnavailable, retryable: true),
        ])
        #expect(startup.sourceFactory.sources.first?.cancelCount == 1)
    }

    @Test
    func invalidTwentyMillisecondFrameFailsClosedBeforeDecoder() throws {
        let dependencies = TestDependencies()
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "invalid-frame"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(VoicePCMFrame(samples: Array(
            repeating: 0,
            count: VoicePCMFrame.samplesPerFrame - 1
        )))

        #expect(waitUntil {
            collector.events == [.failed(.asrEngineError, retryable: true)]
        })
        #expect(dependencies.driver.acceptedSamples.isEmpty)
        #expect(source.cancelCount == 1)
    }

    @Test
    func driverAcceptErrorFailsClosedAndCancelsTheSource() throws {
        let dependencies = TestDependencies()
        dependencies.driver.acceptError = TestFailure.expected
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "driver-failure"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame())

        #expect(waitUntil {
            collector.events == [.failed(.asrEngineError, retryable: true)]
        })
        #expect(source.cancelCount == 1)
        #expect(dependencies.driver.cancelCount == 1)
    }

    @Test
    func driverResetAndFinishErrorsBothFailClosed() throws {
        let reset = TestDependencies()
        reset.driver.resetError = TestFailure.expected
        let resetEngine = try reset.makeEngine()
        let resetEvents = TestEventCollector()
        resetEngine.start(
            makeRequest(id: "driver-reset"),
            events: resetEvents.append
        )
        #expect(resetEvents.events == [
            .failed(.asrEngineError, retryable: true),
        ])
        #expect(reset.sourceFactory.sources.first?.cancelCount == 1)

        let finish = TestDependencies()
        finish.driver.finishError = TestFailure.expected
        let finishEngine = try finish.makeEngine()
        let finishEvents = TestEventCollector()
        finishEngine.start(
            makeRequest(id: "driver-finish"),
            events: finishEvents.append
        )
        finishEngine.stop(requestID: "driver-finish")
        #expect(waitUntil {
            finishEvents.events == [
                .failed(.asrEngineError, retryable: true),
            ]
        })
        #expect(finish.sourceFactory.sources.first?.cancelCount == 1)
    }

    @Test
    func oneHundredFrameFIFOOverloadFailsRetryablyWithoutDecodingOverflow()
        throws
    {
        let dependencies = TestDependencies()
        let gate = TestBlockingGate()
        dependencies.driver.acceptGate = gate
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "ring-overflow"), events: collector.append)
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame(marker: 1))
        #expect(gate.waitUntilEntered())

        for marker in 2...102 {
            source.emit(validFrame(marker: Float(marker)))
        }

        #expect(waitUntil {
            collector.events == [
                .failed(.asrOverload, retryable: true),
            ]
        })
        #expect(source.cancelCount == 1)
        #expect(dependencies.driver.acceptedSamples.count == 1)

        gate.release()
        #expect(waitUntil { dependencies.driver.cancelCount == 1 })
        #expect(dependencies.driver.acceptedSamples.count == 1)
    }

    @Test
    func validatedHotwordSnapshotIsBoundedAndPassedToDriver() throws {
        let dependencies = TestDependencies()
        dependencies.hotwordProvider.phrases = [
            "API", "接口", "模型", "超额",
        ]
        let request = makeRequest(id: "hotwords")
        let engine = try dependencies.makeEngine(
            descriptor: makeProductDescriptor(maximumHotwords: 3)
        )

        engine.start(request, events: { _ in })

        #expect(dependencies.hotwordProvider.requests == [request])
        #expect(dependencies.hotwordProvider.maximumEntries == [3])
        #expect(dependencies.driver.resetHotwordBatches == [[
            "API", "接口", "模型",
        ]])

        engine.cancel(requestID: request.requestID)
    }

    @Test
    func wireHotwordsRemainRequestScopedAcrossLatestWinsAndCancel() throws {
        let dependencies = TestDependencies()
        let engine = try ProductStreamingVoiceEngine(
            descriptor: makeProductDescriptor(maximumHotwords: 2),
            sourceFactory: dependencies.sourceFactory,
            recognizerDriver: dependencies.driver,
            hotwordProvider: RequestVoiceHotwordProvider(),
            scheduleAfterMilliseconds: dependencies.scheduler.schedule
        )
        let core = VoiceDictationServerCore(engine: engine)

        let helloOutputs = try routeThroughVoiceWire(
            .hello(VoiceHelloRequest()),
            to: core
        )
        guard case let .ready(ready)? = helloOutputs.first else {
            Issue.record("expected product engine ready response")
            return
        }
        #expect(ready.capabilities.contains("hotword_snapshot"))
        #expect(ready.maximumHotwords == 2)

        let first = try VoiceHotwordSnapshot(
            phrases: ["AlphaAPI", "第一会话"]
        )
        let second = try VoiceHotwordSnapshot(
            phrases: ["BetaSDK", "第二会话"]
        )
        let third = try VoiceHotwordSnapshot(
            phrases: ["GammaCLI", "第三会话"]
        )

        #expect(try routeThroughVoiceWire(
            .start(makeWireStart(id: "wire-first", hotwords: first)),
            to: core
        ).isEmpty)
        let firstSource = try #require(dependencies.sourceFactory.sources.first)
        #expect(dependencies.driver.resetHotwordBatches == [first.phrases])

        // A newer wire start must cancel the active request before installing
        // its own immutable snapshot; phrases from the old request cannot be
        // merged into the new native stream.
        #expect(try routeThroughVoiceWire(
            .start(makeWireStart(id: "wire-second", hotwords: second)),
            to: core
        ).isEmpty)
        let secondSource = try #require(dependencies.sourceFactory.sources.last)
        #expect(firstSource.cancelCount == 1)
        #expect(dependencies.driver.resetHotwordBatches == [
            first.phrases,
            second.phrases,
        ])

        let cancelCountBeforeStaleCancel = dependencies.driver.cancelCount
        #expect(try routeThroughVoiceWire(
            .cancel(VoiceDictationCancel(
                requestID: "wire-first",
                reason: .sessionSwitch
            )),
            to: core
        ).isEmpty)
        #expect(secondSource.cancelCount == 0)
        #expect(dependencies.driver.cancelCount == cancelCountBeforeStaleCancel)

        #expect(try routeThroughVoiceWire(
            .cancel(VoiceDictationCancel(
                requestID: "wire-second",
                reason: .userAbort
            )),
            to: core
        ).isEmpty)
        #expect(waitUntil {
            secondSource.cancelCount == 1
                && dependencies.driver.cancelCount
                    == cancelCountBeforeStaleCancel + 1
        })

        #expect(try routeThroughVoiceWire(
            .start(makeWireStart(id: "wire-third", hotwords: third)),
            to: core
        ).isEmpty)
        #expect(dependencies.driver.resetHotwordBatches == [
            first.phrases,
            second.phrases,
            third.phrases,
        ])

        let thirdSource = try #require(dependencies.sourceFactory.sources.last)
        let cancelCountBeforeCleanup = dependencies.driver.cancelCount
        _ = try routeThroughVoiceWire(
            .cancel(VoiceDictationCancel(
                requestID: "wire-third",
                reason: .userAbort
            )),
            to: core
        )
        #expect(waitUntil {
            thirdSource.cancelCount == 1
                && dependencies.driver.cancelCount
                    == cancelCountBeforeCleanup + 1
        })
    }

    @Test
    func hotwordProviderErrorFailsClosedBeforeCreatingAudioSource() throws {
        let dependencies = TestDependencies()
        dependencies.hotwordProvider.error = TestFailure.expected
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(makeRequest(id: "hotword-error"), events: collector.append)

        #expect(collector.events == [
            .failed(.asrEngineError, retryable: true),
        ])
        #expect(dependencies.sourceFactory.makeCount == 0)
        #expect(dependencies.driver.resetHotwordBatches.isEmpty)
    }

    @Test
    func maximumDurationStopsTheSourceAndFinalizesInQueueOrder() throws {
        let dependencies = TestDependencies()
        dependencies.driver.finishUpdate = .init(
            text: "自动结束",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(
            makeRequest(id: "maximum", maximumDurationMilliseconds: 125),
            events: collector.append
        )
        let source = try #require(dependencies.sourceFactory.sources.first)
        #expect(dependencies.scheduler.fire(milliseconds: 125))

        #expect(waitUntil {
            collector.events == [.finished(
                text: "自动结束",
                confidence: 0,
                polishApplied: false
            )]
        })
        #expect(source.stopCount == 1)
        #expect(source.cancelCount == 0)
        #expect(dependencies.driver.cancelCount == 1)
    }

    @Test
    func finalDeadlineTimesOutAndDropsTheLateDriverResult() throws {
        let dependencies = TestDependencies()
        let finishGate = TestBlockingGate()
        dependencies.driver.finishGate = finishGate
        dependencies.driver.finishUpdate = .init(
            text: "迟到结果",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()

        engine.start(
            makeRequest(id: "deadline", deadlineMilliseconds: 17),
            events: collector.append
        )
        engine.stop(requestID: "deadline")
        #expect(finishGate.waitUntilEntered())
        #expect(dependencies.scheduler.fire(milliseconds: 17))
        #expect(collector.events == [
            .failed(.asrTimeout, retryable: true),
        ])

        finishGate.release()
        #expect(waitUntil { dependencies.driver.cancelCount == 1 })
        Thread.sleep(forTimeInterval: 0.01)
        #expect(collector.events == [
            .failed(.asrTimeout, retryable: true),
        ])
    }

    @Test
    func lateFrameFromCancelledGenerationCannotEnterTheNextSession() throws {
        let dependencies = TestDependencies()
        let engine = try dependencies.makeEngine()
        let oldEvents = TestEventCollector()
        let newEvents = TestEventCollector()

        engine.start(makeRequest(id: "old"), events: oldEvents.append)
        let oldSource = try #require(dependencies.sourceFactory.sources.first)
        engine.cancel(requestID: "old")

        engine.start(makeRequest(id: "new"), events: newEvents.append)
        let newSource = try #require(dependencies.sourceFactory.sources.last)
        oldSource.emit(validFrame(marker: 1))
        newSource.emit(validFrame(marker: 2))

        #expect(waitUntil { dependencies.driver.acceptedSamples.count == 1 })
        #expect(dependencies.driver.acceptedSamples.map { $0[0] } == [2])
        #expect(oldEvents.events.isEmpty)
        #expect(newEvents.events.isEmpty)

        engine.cancel(requestID: "new")
    }

    @Test
    func blockedOldResetThenCancelCannotOverrideTheNewGeneration() throws {
        let dependencies = TestDependencies()
        let oldResetGate = TestBlockingGate()
        dependencies.driver.enqueueResetGates([oldResetGate, nil])
        let engine = try dependencies.makeEngine()
        let oldEvents = TestEventCollector()
        let newEvents = TestEventCollector()
        let oldStartReturned = DispatchSemaphore(value: 0)
        let newStartReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            engine.start(makeRequest(id: "blocked-old"), events: oldEvents.append)
            oldStartReturned.signal()
        }
        #expect(oldResetGate.waitUntilEntered())

        engine.cancel(requestID: "blocked-old")
        DispatchQueue.global().async {
            engine.start(makeRequest(id: "fresh"), events: newEvents.append)
            newStartReturned.signal()
        }

        oldResetGate.release()
        #expect(oldStartReturned.wait(timeout: .now() + 1) == .success)
        #expect(newStartReturned.wait(timeout: .now() + 1) == .success)

        let sources = dependencies.sourceFactory.sources
        #expect(sources.count == 2)
        #expect(sources[0].startCount == 0)
        #expect(sources[0].cancelCount == 1)
        #expect(sources[1].startCount == 1)
        #expect(dependencies.driver.calls.prefix(3)
            == ["startSession", "cancel", "startSession"])
        #expect(oldEvents.events.isEmpty)
        #expect(newEvents.events.isEmpty)

        engine.cancel(requestID: "fresh")
    }

    @Test
    func stopDuringPreparationIsRememberedWithoutStartingTheSource() throws {
        let dependencies = TestDependencies()
        let preparationGate = TestBlockingGate()
        dependencies.hotwordProvider.snapshotGate = preparationGate
        dependencies.driver.finishUpdate = .init(
            text: "准备期停止",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()
        let startReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            engine.start(
                makeRequest(id: "preparation-stop"),
                events: collector.append
            )
            startReturned.signal()
        }
        #expect(preparationGate.waitUntilEntered())

        engine.stop(requestID: "preparation-stop")
        preparationGate.release()

        #expect(startReturned.wait(timeout: .now() + 1) == .success)
        #expect(waitUntil {
            collector.events == [.finished(
                text: "准备期停止",
                confidence: 0,
                polishApplied: false
            )]
        })
        let source = try #require(dependencies.sourceFactory.sources.first)
        #expect(source.startCount == 0)
        #expect(source.stopCount == 1)
    }

    @Test
    func stopWhileResetIsBlockedRevokesTheSourceStartPermit() throws {
        let dependencies = TestDependencies()
        let resetGate = TestBlockingGate()
        dependencies.driver.enqueueResetGates([resetGate])
        dependencies.driver.finishUpdate = .init(
            text: "重置期停止",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let collector = TestEventCollector()
        let startReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            engine.start(
                makeRequest(id: "reset-stop"),
                events: collector.append
            )
            startReturned.signal()
        }
        #expect(resetGate.waitUntilEntered())
        let source = try #require(dependencies.sourceFactory.sources.first)

        engine.stop(requestID: "reset-stop")
        #expect(source.stopCount == 1)
        resetGate.release()

        #expect(startReturned.wait(timeout: .now() + 1) == .success)
        #expect(waitUntil {
            collector.events == [.finished(
                text: "重置期停止",
                confidence: 0,
                polishApplied: false
            )]
        })
        #expect(source.startCount == 0)
    }

    @Test
    func cancelWhileResetIsBlockedPreventsAnyLaterSourceStart() throws {
        let dependencies = TestDependencies()
        let resetGate = TestBlockingGate()
        dependencies.driver.enqueueResetGates([resetGate])
        let engine = try dependencies.makeEngine()
        let startReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            engine.start(makeRequest(id: "reset-cancel"), events: { _ in })
            startReturned.signal()
        }
        #expect(resetGate.waitUntilEntered())
        let source = try #require(dependencies.sourceFactory.sources.first)

        engine.cancel(requestID: "reset-cancel")
        #expect(source.cancelCount == 1)
        #expect(source.startCount == 0)
        resetGate.release()

        #expect(startReturned.wait(timeout: .now() + 1) == .success)
        #expect(source.startCount == 0)
    }

    @Test
    func finishedSinkCanSynchronouslyStartTheNextSession() throws {
        let dependencies = TestDependencies()
        dependencies.driver.finishUpdate = .init(
            text: "完成",
            isEndpoint: false
        )
        let engine = try dependencies.makeEngine()
        let nextStarted = DispatchSemaphore(value: 0)

        engine.start(makeRequest(id: "terminal-first")) { event in
            guard case .finished = event else { return }
            engine.start(makeRequest(id: "terminal-next"), events: { _ in })
            nextStarted.signal()
        }
        engine.stop(requestID: "terminal-first")

        #expect(nextStarted.wait(timeout: .now() + 1) == .success)
        #expect(dependencies.sourceFactory.sources.count == 2)
        #expect(dependencies.sourceFactory.sources.last?.startCount == 1)
        #expect(dependencies.driver.calls == [
            "startSession", "finish", "cancel", "startSession",
        ])
        engine.cancel(requestID: "terminal-next")
    }

    @Test
    func failedSinkCanSynchronouslyStartTheNextSession() throws {
        let dependencies = TestDependencies()
        dependencies.driver.acceptError = TestFailure.expected
        let engine = try dependencies.makeEngine()
        let nextStarted = DispatchSemaphore(value: 0)

        engine.start(makeRequest(id: "failure-first")) { event in
            guard case .failed = event else { return }
            engine.start(makeRequest(id: "failure-next"), events: { _ in })
            nextStarted.signal()
        }
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame())

        #expect(nextStarted.wait(timeout: .now() + 1) == .success)
        #expect(dependencies.sourceFactory.sources.count == 2)
        #expect(dependencies.sourceFactory.sources.last?.startCount == 1)
        engine.cancel(requestID: "failure-next")
    }

    @Test
    func partialSinkMayWaitForCancellationFromAnotherThread() throws {
        let dependencies = TestDependencies()
        dependencies.driver.enqueueAcceptUpdates([
            .init(text: "等待取消", isEndpoint: false),
        ])
        let engine = try dependencies.makeEngine()
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let sinkReturned = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)

        engine.start(makeRequest(id: "cross-thread-cancel")) { event in
            guard case .partial = event else { return }
            sinkEntered.signal()
            releaseSink.wait()
            sinkReturned.signal()
        }
        let source = try #require(dependencies.sourceFactory.sources.first)
        source.emit(validFrame())
        #expect(sinkEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            engine.cancel(requestID: "cross-thread-cancel")
            cancelReturned.signal()
        }
        let cancelResult = cancelReturned.wait(timeout: .now() + 1)
        releaseSink.signal()

        #expect(cancelResult == .success)
        #expect(sinkReturned.wait(timeout: .now() + 1) == .success)
        #expect(source.cancelCount == 1)
    }

    @Test
    func realAVSourceCaptureFailureCancelsWithoutCallbackQueueDeadlock()
        throws
    {
        let authorization = ProductTestMicrophoneAuthorization()
        let capture = ProductTestPCMInputCapture()
        let source = AVAudioEnginePCMSource(
            authorizationProvider: authorization,
            capture: capture,
            converterFactory: { ProductTestPCMConverter() }
        )
        let sourceFactory = ProductTestAVSourceFactory(source: source)
        let driver = TestRecognizerDriver()
        let scheduler = TestManualScheduler()
        let engine = try ProductStreamingVoiceEngine(
            descriptor: makeProductDescriptor(),
            sourceFactory: sourceFactory,
            recognizerDriver: driver,
            hotwordProvider: TestHotwordProvider(),
            scheduleAfterMilliseconds: scheduler.schedule
        )
        let collector = TestEventCollector()

        engine.start(
            makeRequest(id: "real-av-source-failure"),
            events: collector.append
        )
        #expect(capture.startCount == 1)

        capture.emitFailure()

        #expect(waitUntil {
            collector.events == [
                .failed(.micUnavailable, retryable: false),
            ]
        })
        // The terminal event is emitted only after SourceLifecycle.cancel has
        // synchronously crossed the AV source's callback fence.
        #expect(capture.stopCount == 1)
        #expect(driver.cancelCount == 1)

        let nextCollector = TestEventCollector()
        engine.start(
            makeRequest(id: "real-av-source-after-failure"),
            events: nextCollector.append
        )
        #expect(capture.startCount == 2)
        engine.cancel(requestID: "real-av-source-after-failure")
        #expect(waitUntil { driver.cancelCount == 2 })
        #expect(nextCollector.events.isEmpty)
    }
}

private enum TestFailure: Error {
    case expected
}

private struct ProductTestMicrophoneAuthorization:
    VoiceMicrophoneAuthorizationProviding,
    Sendable
{
    func authorizationStatus() -> VoiceMicrophoneAuthorizationState {
        .authorized
    }

    func requestAuthorization(
        _ completion: @escaping @Sendable (VoiceMicrophoneAuthorizationState) -> Void
    ) {
        completion(.authorized)
    }
}

private final class ProductTestPCMInputCapture:
    VoicePCMInputCapturing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var failureHandler:
        (@Sendable (VoicePCMInputCaptureFailure) -> Void)?
    private var startCountStorage = 0
    private var stopCountStorage = 0

    func start(
        onChunk: @escaping @Sendable (VoicePCMInputChunk) -> Void,
        onFailure: @escaping @Sendable (VoicePCMInputCaptureFailure) -> Void
    ) throws {
        lock.lock()
        startCountStorage += 1
        failureHandler = onFailure
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopCountStorage += 1
        failureHandler = nil
        lock.unlock()
    }

    func emitFailure() {
        lock.lock()
        let handler = failureHandler
        lock.unlock()
        handler?(.invalidInput)
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCountStorage
    }
}

private final class ProductTestPCMConverter:
    VoicePCMConverting,
    @unchecked Sendable
{
    func append(_ chunk: VoicePCMInputChunk) throws -> [VoicePCMFrame] {
        []
    }

    func finish(padTail: Bool) throws -> [VoicePCMFrame] { [] }

    func discard() {}
}

private struct ProductTestAVSourceFactory: VoicePCMSourceFactory, Sendable {
    let source: AVAudioEnginePCMSource

    func makeSource() throws -> any VoicePCMSource { source }
}

private final class TestBlockingGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func release() {
        released.signal()
    }
}

private final class TestDependencies: @unchecked Sendable {
    let sourceFactory = TestPCMSourceFactory()
    let driver = TestRecognizerDriver()
    let hotwordProvider = TestHotwordProvider()
    let scheduler = TestManualScheduler()

    func makeEngine(
        descriptor: VoiceEngineDescriptor = makeProductDescriptor()
    ) throws -> ProductStreamingVoiceEngine {
        try ProductStreamingVoiceEngine(
            descriptor: descriptor,
            sourceFactory: sourceFactory,
            recognizerDriver: driver,
            hotwordProvider: hotwordProvider,
            scheduleAfterMilliseconds: scheduler.schedule
        )
    }
}

private final class TestManualScheduler: @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        let milliseconds: Int
        let operation: @Sendable () -> Void
        var isCancelled = false
        var hasFired = false

        init(milliseconds: Int, operation: @escaping @Sendable () -> Void) {
            self.milliseconds = milliseconds
            self.operation = operation
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func schedule(
        _ milliseconds: Int,
        _ operation: @escaping @Sendable () -> Void
    ) -> ProductStreamingVoiceScheduledCancellation {
        let entry = Entry(milliseconds: milliseconds, operation: operation)
        lock.lock()
        entries.append(entry)
        lock.unlock()
        return { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.lock.lock()
            entry.isCancelled = true
            self.lock.unlock()
        }
    }

    func fire(milliseconds: Int) -> Bool {
        lock.lock()
        guard let entry = entries.first(where: {
            $0.milliseconds == milliseconds
                && !$0.isCancelled
                && !$0.hasFired
        }) else {
            lock.unlock()
            return false
        }
        entry.hasFired = true
        lock.unlock()
        entry.operation()
        return true
    }
}

private final class TestPCMSourceFactory: VoicePCMSourceFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var sourceStorage: [TestPCMSource] = []
    private var makeCountStorage = 0
    private var makeErrorStorage: (any Error)?
    private var nextSourceStartErrorStorage: (any Error)?

    func makeSource() throws -> any VoicePCMSource {
        lock.lock()
        makeCountStorage += 1
        if let makeErrorStorage {
            lock.unlock()
            throw makeErrorStorage
        }
        let source = TestPCMSource(startError: nextSourceStartErrorStorage)
        nextSourceStartErrorStorage = nil
        sourceStorage.append(source)
        lock.unlock()
        return source
    }

    var sources: [TestPCMSource] {
        lock.lock()
        defer { lock.unlock() }
        return sourceStorage
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return makeCountStorage
    }


    var makeError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return makeErrorStorage
        }
        set {
            lock.lock()
            makeErrorStorage = newValue
            lock.unlock()
        }
    }

    var nextSourceStartError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return nextSourceStartErrorStorage
        }
        set {
            lock.lock()
            nextSourceStartErrorStorage = newValue
            lock.unlock()
        }
    }
}

private final class TestPCMSource: VoicePCMSource, @unchecked Sendable {
    private let lock = NSLock()
    private var startCountStorage = 0
    private var frameHandler: (@Sendable (VoicePCMFrame) -> Void)?
    private var failureHandler: (@Sendable (VoicePCMSourceFailure) -> Void)?
    private var stopCountStorage = 0
    private var cancelCountStorage = 0
    private var onStopStorage: (@Sendable () -> Void)?
    private let startError: (any Error)?

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {
        lock.lock()
        startCountStorage += 1
        frameHandler = onFrame
        failureHandler = onFailure
        lock.unlock()
        if let startError {
            throw startError
        }
    }

    func stop() {
        lock.lock()
        stopCountStorage += 1
        let action = onStopStorage
        lock.unlock()
        action?()
    }
    func cancel() {
        lock.lock()
        cancelCountStorage += 1
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    func emit(_ frame: VoicePCMFrame) {
        lock.lock()
        let callback = frameHandler
        lock.unlock()
        callback?(frame)
    }

    func fail(_ failure: VoicePCMSourceFailure) {
        lock.lock()
        let callback = failureHandler
        lock.unlock()
        callback?(failure)
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCountStorage
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountStorage
    }

    var onStop: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onStopStorage
        }
        set {
            lock.lock()
            onStopStorage = newValue
            lock.unlock()
        }
    }
}

private final class TestRecognizerDriver: VoiceStreamingRecognizerDriver,
    @unchecked Sendable
{
    private let lock = NSLock()
    var artifactGeneration = productArtifactGeneration
    private var resetHotwordBatchesStorage: [[String]] = []
    private var endpointResetCountStorage = 0
    private var acceptUpdates: [VoiceStreamingRecognitionUpdate] = []
    private var acceptedSamplesStorage: [[Float]] = []
    private var finishUpdateStorage = VoiceStreamingRecognitionUpdate(
        text: "",
        isEndpoint: false
    )
    private var callStorage: [String] = []
    private var cancelCountStorage = 0
    private var acceptErrorStorage: (any Error)?
    private var resetErrorStorage: (any Error)?
    private var finishErrorStorage: (any Error)?
    private var acceptGateStorage: TestBlockingGate?
    private var finishGateStorage: TestBlockingGate?
    private var resetGatesStorage: [TestBlockingGate?] = []

    func startSession(hotwords: [String]) throws {
        lock.lock()
        callStorage.append("startSession")
        resetHotwordBatchesStorage.append(hotwords)
        if let resetErrorStorage {
            lock.unlock()
            throw resetErrorStorage
        }
        let gate = resetGatesStorage.isEmpty
            ? nil
            : resetGatesStorage.removeFirst()
        lock.unlock()
        gate?.block()
    }

    func resetEndpoint() throws {
        lock.lock()
        callStorage.append("resetEndpoint")
        endpointResetCountStorage += 1
        if let resetErrorStorage {
            lock.unlock()
            throw resetErrorStorage
        }
        lock.unlock()
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        lock.lock()
        callStorage.append("accept")
        acceptedSamplesStorage.append(samples)
        if let acceptErrorStorage {
            lock.unlock()
            throw acceptErrorStorage
        }
        let gate = acceptGateStorage
        let update = acceptUpdates.isEmpty
            ? VoiceStreamingRecognitionUpdate(text: "", isEndpoint: false)
            : acceptUpdates.removeFirst()
        lock.unlock()
        gate?.block()
        return update
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        lock.lock()
        callStorage.append("finish")
        if let finishErrorStorage {
            lock.unlock()
            throw finishErrorStorage
        }
        let update = finishUpdateStorage
        let gate = finishGateStorage
        lock.unlock()
        gate?.block()
        return update
    }

    func cancel() {
        lock.lock()
        callStorage.append("cancel")
        cancelCountStorage += 1
        lock.unlock()
    }

    var resetHotwordBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return resetHotwordBatchesStorage
    }

    var endpointResetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endpointResetCountStorage
    }

    func enqueueAcceptUpdates(
        _ updates: [VoiceStreamingRecognitionUpdate]
    ) {
        lock.lock()
        acceptUpdates.append(contentsOf: updates)
        lock.unlock()
    }

    var acceptedSamples: [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return acceptedSamplesStorage
    }

    var finishUpdate: VoiceStreamingRecognitionUpdate {
        get {
            lock.lock()
            defer { lock.unlock() }
            return finishUpdateStorage
        }
        set {
            lock.lock()
            finishUpdateStorage = newValue
            lock.unlock()
        }
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callStorage
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountStorage
    }


    var acceptError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return acceptErrorStorage
        }
        set {
            lock.lock()
            acceptErrorStorage = newValue
            lock.unlock()
        }
    }

    var resetError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return resetErrorStorage
        }
        set {
            lock.lock()
            resetErrorStorage = newValue
            lock.unlock()
        }
    }

    var finishError: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return finishErrorStorage
        }
        set {
            lock.lock()
            finishErrorStorage = newValue
            lock.unlock()
        }
    }

    var acceptGate: TestBlockingGate? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return acceptGateStorage
        }
        set {
            lock.lock()
            acceptGateStorage = newValue
            lock.unlock()
        }
    }

    var finishGate: TestBlockingGate? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return finishGateStorage
        }
        set {
            lock.lock()
            finishGateStorage = newValue
            lock.unlock()
        }
    }

    func enqueueResetGates(_ gates: [TestBlockingGate?]) {
        lock.lock()
        resetGatesStorage.append(contentsOf: gates)
        lock.unlock()
    }
}

private func validFrame(marker: Float = 0) -> VoicePCMFrame {
    VoicePCMFrame(samples: Array(
        repeating: marker,
        count: VoicePCMFrame.samplesPerFrame
    ))
}

private func waitUntil(
    timeout: TimeInterval = 1,
    _ predicate: @escaping @Sendable () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return predicate()
}

private final class TestHotwordProvider: VoiceHotwordProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var phrasesStorage: [String] = []
    private var errorStorage: (any Error)?
    private var requestStorage: [VoiceDictationEngineRequest] = []
    private var maximumEntriesStorage: [Int] = []
    private var snapshotGateStorage: TestBlockingGate?

    func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot {
        lock.lock()
        requestStorage.append(request)
        maximumEntriesStorage.append(maximumEntries)
        if let errorStorage {
            lock.unlock()
            throw errorStorage
        }
        let phrases = phrasesStorage
        let gate = snapshotGateStorage
        lock.unlock()
        gate?.block()
        return try VoiceHotwordSnapshot(phrases: phrases).limited(
            to: maximumEntries
        )
    }

    var phrases: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return phrasesStorage
        }
        set {
            lock.lock()
            phrasesStorage = newValue
            lock.unlock()
        }
    }

    var error: (any Error)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return errorStorage
        }
        set {
            lock.lock()
            errorStorage = newValue
            lock.unlock()
        }
    }

    var requests: [VoiceDictationEngineRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    var maximumEntries: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return maximumEntriesStorage
    }

    var snapshotGate: TestBlockingGate? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return snapshotGateStorage
        }
        set {
            lock.lock()
            snapshotGateStorage = newValue
            lock.unlock()
        }
    }
}

private final class TestEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VoiceDictationEngineEvent] = []

    func append(_ event: VoiceDictationEngineEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [VoiceDictationEngineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func makeRequest(
    id: String,
    deadlineMilliseconds: Int = 50,
    maximumDurationMilliseconds: Int = 1_000
) -> VoiceDictationEngineRequest {
    VoiceDictationEngineRequest(
        requestID: id,
        wireRequestID: "wire-\(id)",
        compositionID: "2CAFDFF1-2719-44DC-BCFA-11541314AC76",
        applicationSessionID: "tests#\(id)",
        bundleID: "com.example.tests",
        mode: .direct,
        deadlineMilliseconds: deadlineMilliseconds,
        maximumDurationMilliseconds: maximumDurationMilliseconds
    )
}

private func makeWireStart(
    id: String,
    hotwords: VoiceHotwordSnapshot
) -> VoiceDictationStart {
    VoiceDictationStart(
        requestID: id,
        compositionID: UUID(),
        appSessionID: "tests#\(id)",
        bundleID: "com.example.tests",
        mode: .direct,
        deadlineMilliseconds: 50,
        maximumDurationMilliseconds: 1_000,
        hotwordSnapshot: hotwords
    )
}

private func routeThroughVoiceWire(
    _ message: VoiceClientMessage,
    to core: VoiceDictationServerCore
) throws -> [VoiceDictationServerCore.Output] {
    let payload = try VoiceDictationWire.encodeXPCPayload(message)
    switch try VoiceDictationWire.decodeXPCClientPayload(payload) {
    case .hello(let value):
        return core.handle(value)
    case .start(let value):
        return core.handle(value)
    case .stop(let value):
        return core.handle(value)
    case .cancel(let value):
        return core.handle(value)
    case .accept(let value):
        return core.handle(value)
    }
}

private func makeProductDescriptor(
    qualification: VoiceEngineQualification =
        .integrityVerifiedProductArtifact,
    networkPolicy: VoiceNetworkPolicy = .offline,
    capabilities: Set<VoiceEngineCapability> = [
        .localASR, .streaming, .hotwordSnapshot,
    ],
    audioFormat: VoiceEngineAudioFormat = .fixedLinearPCM(
        sampleRateHertz: 16_000,
        channelCount: 1,
        bitsPerChannel: 32
    ),
    maximumAlternatives: Int = 1,
    maximumHotwords: Int = 8
) -> VoiceEngineDescriptor {
    VoiceEngineDescriptor(
        adapterID: "sherpa-onnx-online-transducer",
        adapterVersion: "1.13.6",
        assetManagement: .productManaged,
        qualification: qualification,
        artifactID: VoiceASRArtifactID(rawValue: "test-voice-artifact"),
        artifactSHA256: String(repeating: "a", count: 64),
        artifactGeneration: productArtifactGeneration,
        supportedLocales: ["zh-CN"],
        capabilities: capabilities,
        networkPolicy: networkPolicy,
        audioFormat: audioFormat,
        hotwordMode: .boundedPhraseList(maximumEntries: maximumHotwords),
        maximumAlternatives: maximumAlternatives
    )
}

private let productArtifactGeneration = UUID(
    uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
)!
