/*
 * Minimal reactive plumbing, shared by the whole data layer.
 *
 * The iOS app got these from RxSwift / RxRelay, which have no HarmonyOS equivalent and are
 * resolved `native` in results/analysis/inventory.json (dependencies[]): "plain ArkTS
 * callbacks / @State + @Observed". That is the "capability, not library" rule (CLAUDE.md
 * Rule 10) - same names, same semantics, no operators.
 *
 * This module exists because ArkTS is NOMINALLY typed: if each service declared its own
 * BehaviorRelay, two of them would not be interchangeable even with identical bodies.
 * Every model and service imports these from here.
 *
 * Nothing here talks to the jami daemon.
 */

/** RxSwift `DisposeBag` - holds the unsubscribe closures of its owner's subscriptions. */
export class DisposeBag {
  private disposables: Array<() => void> = [];

  add(dispose: () => void): void {
    this.disposables.push(dispose);
  }

  dispose(): void {
    try {
      for (const disposable of this.disposables) {
        disposable();
      }
    } finally {
      this.disposables = [];
    }
  }
}

/** RxSwift `PublishSubject` - fires only values emitted after a subscription starts. */
export class PublishSubject<T> {
  private observers: Array<(value: T) => void> = [];

  /** Returns the unsubscribe closure; hand it to a DisposeBag. */
  subscribe(observer: (value: T) => void): () => void {
    this.observers.push(observer);
    return () => {
      const index: number = this.observers.indexOf(observer);
      if (index >= 0) {
        this.observers.splice(index, 1);
      }
    };
  }

  onNext(value: T): void {
    const snapshot: Array<(value: T) => void> = this.observers.slice();
    for (const observer of snapshot) {
      observer(value);
    }
  }
}

/** RxRelay `BehaviorRelay` - a PublishSubject that also replays its current value. */
export class BehaviorRelay<T> extends PublishSubject<T> {
  private current: T;

  constructor(value: T) {
    super();
    this.current = value;
  }

  get value(): T {
    return this.current;
  }

  accept(value: T): void {
    this.current = value;
    this.onNext(value);
  }

  subscribe(observer: (value: T) => void): () => void {
    const dispose: () => void = super.subscribe(observer);
    observer(this.current);
    return dispose;
  }
}
