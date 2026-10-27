namespace Whisp.Core.Input;

/// <summary>
/// Runs a caret read on one budget. The character before the cursor is published
/// as soon as the read reports it, so later reads that miss the budget cannot drop it.
/// </summary>
public static class CaretLookup
{
    public readonly struct Result<T> where T : struct
    {
        public char? Preceding { get; init; }
        public T Snapshot { get; init; }
        /// False when the read was still running at the budget.
        public bool Completed { get; init; }
    }

    public readonly struct Tasks<T> where T : struct
    {
        public Task<char?> Preceding { get; init; }
        public Task<T> Snapshot { get; init; }
        public Task<bool> Completed { get; init; }
    }

    /// <paramref name="budgetDelay"/> replaces the real timer in tests.
    /// The read calls the action once, before any slower follow-up work.
    public static Tasks<T> Start<T>(TimeSpan budget, Func<Action<char?>, T> read,
        Func<TimeSpan, Task>? budgetDelay = null) where T : struct
    {
        var delivered = new TaskCompletionSource<char?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var budgetDone = budgetDelay?.Invoke(budget) ?? Task.Delay(budget);
        var work = Task.Run(() =>
        {
            try
            {
                return read(value => delivered.TrySetResult(value));
            }
            catch (Exception)
            {
                // A failed read is "no character", not a lost one. TrySetResult
                // does nothing if the character was already published.
                delivered.TrySetResult(null);
                return default;
            }
        });

        var completed = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var snapshot = Task.WhenAny(work, budgetDone).ContinueWith(_ =>
        {
            var done = work.IsCompletedSuccessfully;
            completed.TrySetResult(done);
            return done ? work.Result : default;
        });
        var preceding = Task.WhenAny(delivered.Task, budgetDone, work).ContinueWith(_ =>
            delivered.Task.IsCompletedSuccessfully ? delivered.Task.Result : null);

        return new Tasks<T> { Preceding = preceding, Snapshot = snapshot, Completed = completed.Task };
    }

    public static async Task<Result<T>> Run<T>(TimeSpan budget, Func<Action<char?>, T> read,
        Func<TimeSpan, Task>? budgetDelay = null) where T : struct
    {
        var tasks = Start(budget, read, budgetDelay);
        await Task.WhenAll(tasks.Preceding, tasks.Snapshot, tasks.Completed);
        return new Result<T>
        {
            Preceding = tasks.Preceding.Result,
            Snapshot = tasks.Snapshot.Result,
            Completed = tasks.Completed.Result,
        };
    }
}
