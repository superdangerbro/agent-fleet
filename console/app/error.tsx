"use client";

export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="card">
      <h1>Something failed</h1>
      <pre>{error.message}</pre>
      <p className="row" style={{ marginTop: 10 }}>
        <button onClick={() => reset()}>Try again</button>
        <a href="javascript:history.back()">Back</a>
      </p>
    </div>
  );
}
