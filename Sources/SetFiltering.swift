//
//  SetFiltering.swift
//  GlueKit
//
//  Created by Károly Lőrentey on 2015-12-12.
//  Copyright © 2015 Károly Lőrentey. All rights reserved.
//

import Foundation

extension ObservableSetType {
    public func filter(_ isIncluded: @escaping (Element) -> Bool) -> ObservableSet<Element> {
        return SetFilteringOnPredicate<Self>(parent: self, test: isIncluded).observableSet
    }

    public func filter<TestResult: ObservableValueType>(_ isIncluded: @escaping (Element) -> TestResult) -> ObservableSet<Element> where TestResult.Value == Bool {
        return SetFilteringOnObservableBool<Self, TestResult>(parent: self, test: isIncluded).observableSet
    }

    public func filter<Predicate: ObservableValueType>(_ isIncluded: Predicate) -> ObservableSet<Element> where Predicate.Value == (Element) -> Bool {
        return self.filter(isIncluded.map { predicate -> Optional<(Element) -> Bool> in predicate })
    }

    public func filter<Predicate: ObservableValueType>(_ isIncluded: Predicate) -> ObservableSet<Element> where Predicate.Value == Optional<(Element) -> Bool> {
        let reference = ObservableSetReference<Element>()
        let connection = isIncluded.values.connect { predicate in
            if let predicate = predicate {
                reference.retarget(to: self.filter(predicate))
            }
            else {
                reference.retarget(to: self)
            }
        }
        return reference.observableSet.holding(connection)
    }
}

private final class SetFilteringOnPredicate<Parent: ObservableSetType>: ObservableSetBase<Parent.Element>, SignalDelegate {
    public typealias Element = Parent.Element
    public typealias Change = SetChange<Element>

    private let parent: Parent
    private let test: (Element) -> Bool

    private var changeSignal = OwningSignal<Change>()

    private var active = false
    private var parentConnection: Connection? = nil
    private var matchingElements: Set<Element> = []

    init(parent: Parent, test: @escaping (Element) -> Bool) {
        self.parent = parent
        self.test = test
    }

    override var isBuffered: Bool { return false }
    override var count: Int {
        if active { return matchingElements.count }
        return parent.value.reduce(0) { test($1) ? $0 + 1 : $0 }
    }
    override var value: Set<Element> {
        if active { return matchingElements }
        return Set(self.parent.value.filter(test))
    }
    override func contains(_ member: Element) -> Bool {
        if active { return matchingElements.contains(member) }
        return self.parent.contains(member) && test(member)
    }

    override func isSubset(of other: Set<Element>) -> Bool {
        if active { return matchingElements.isSubset(of: other) }
        for member in self.parent.value {
            guard test(member) else { continue }
            guard other.contains(member) else { return false }
        }
        return true
    }

    override func isSuperset(of other: Set<Element>) -> Bool {
        if active { return matchingElements.isSuperset(of: other) }
        for member in other {
            guard test(member) && parent.contains(member) else { return false }
        }
        return true
    }

    override var changes: Source<SetChange<Parent.Element>> { return changeSignal.with(self).source }

    internal func start(_ signal: Signal<Change>) {
        active = true
        for e in parent.value {
            if test(e) {
                matchingElements.insert(e)
            }
        }
        parentConnection = parent.changes.connect { [unowned self] change in
            self.apply(change)
        }
    }

    internal func stop(_ signal: Signal<Change>) {
        active = false
        parentConnection?.disconnect()
        parentConnection = nil
        matchingElements = []
    }

    private func apply(_ change: SetChange<Parent.Element>) {
        var c = SetChange<Element>()
        for e in change.removed {
            if let old = matchingElements.remove(e) {
                c.remove(old)
            }
        }
        for e in change.inserted {
            if self.test(e) {
                matchingElements.insert(e)
                c.insert(e)
            }
        }
        if !c.isEmpty {
            changeSignal.send(c)
        }
    }
}

private class SetFilteringOnObservableBool<Parent: ObservableSetType, TestResult: ObservableValueType>: ObservableSetBase<Parent.Element>, SignalDelegate where TestResult.Value == Bool {
    typealias Element = Parent.Element
    typealias Change = SetChange<Element>
    typealias SignalValue = Change

    private let parent: Parent
    private let test: (Element) -> TestResult

    private var signal = OwningSignal<Change>()

    private var active = false
    private var parentConnection: Connection? = nil
    private var elementConnections: [Element: Connection] = [:]
    private var matchingElements: Set<Element> = []

    init(parent: Parent, test: @escaping (Element) -> TestResult) {
        self.parent = parent
        self.test = test
    }

    override var isBuffered: Bool { return false }

    override var count: Int {
        if active { return matchingElements.count }

        var count = 0
        for element in parent.value {
            if test(element).value {
                count += 1
            }
        }
        return count
    }

    override var value: Set<Element> {
        if active { return matchingElements }
        return Set(self.parent.value.filter { test($0).value })
    }

    override func contains(_ member: Element) -> Bool {
        if active { return matchingElements.contains(member) }
        return self.parent.contains(member) && test(member).value
    }

    override func isSubset(of other: Set<Element>) -> Bool {
        if active { return matchingElements.isSubset(of: other) }
        for member in self.parent.value {
            guard test(member).value else { continue }
            guard other.contains(member) else { return false }
        }
        return true
    }

    override func isSuperset(of other: Set<Element>) -> Bool {
        if active { return matchingElements.isSuperset(of: other) }
        for member in other {
            guard test(member).value && parent.contains(member) else { return false }
        }
        return true
    }

    override var changes: Source<SetChange<Parent.Element>> { return signal.with(self).source }

    internal func start(_ signal: Signal<Change>) {
        active = true
        for e in parent.value {
            let test = self.test(e)
            if test.value {
                matchingElements.insert(e)
            }
            let c = test.changes.connect { [unowned self] change in self.apply(change, from: e) }
            elementConnections[e] = c
        }
        parentConnection = parent.changes.connect { [unowned self] change in self.apply(change) }
    }

    internal func stop(_ signal: Signal<Change>) {
        active = false
        parentConnection?.disconnect()
        parentConnection = nil
        elementConnections.forEach { $0.1.disconnect() }
        elementConnections = [:]
        matchingElements = []
    }

    private func apply(_ change: SetChange<Parent.Element>) {
        var c = SetChange<Element>()
        for e in change.removed {
            self.elementConnections.removeValue(forKey: e)!.disconnect()
            if let old = self.matchingElements.remove(e) {
                c.remove(old)
            }
        }
        for e in change.inserted {
            let test = self.test(e)
            self.elementConnections[e] = test.changes.connect { [unowned self] change in self.apply(change, from: e) }
            if test.value {
                self.matchingElements.insert(e)
                c.insert(e)
            }
        }
        if !c.isEmpty {
            self.signal.send(c)
        }
    }

    private func apply(_ change: SimpleChange<Bool>, from element: Parent.Element) {
        if !change.old && change.new {
            matchingElements.insert(element)
            signal.send(SetChange(inserted: [element]))
        }
        else if change.old && !change.new {
            matchingElements.remove(element)
            signal.send(SetChange(removed: [element]))
        }
    }
}