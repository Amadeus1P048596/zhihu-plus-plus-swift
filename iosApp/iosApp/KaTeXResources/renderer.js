"use strict";

window.renderFormula = async function(request) {
  const output = document.getElementById("formula");
  output.replaceChildren();
  output.style.fontSize = request.pointSize + "px";
  output.style.color = request.color;
  output.dataset.displayMode = request.displayMode ? "display" : "inline";
  output.setAttribute("aria-label", request.accessibilityLabel);

  try {
    katex.render(request.latex, output, {
      displayMode: request.displayMode,
      throwOnError: true,
      strict: "ignore",
      trust: false,
      maxExpand: 1000,
      maxSize: 100,
      output: "htmlAndMathml"
    });

    let baselineMarker = null;
    if (!request.displayMode) {
      const katexRoot = output.querySelector(".katex");
      if (!katexRoot) {
        throw new Error("KaTeX produced no measurable output");
      }
      baselineMarker = document.createElement("span");
      baselineMarker.className = "baseline-marker";
      baselineMarker.setAttribute("aria-hidden", "true");
      katexRoot.appendChild(baselineMarker);
    }

    await document.fonts.ready;
    const rect = output.getBoundingClientRect();
    const width = Math.ceil(rect.width);
    const height = Math.ceil(rect.height);
    const baselineFromTop = baselineMarker
      ? baselineMarker.getBoundingClientRect().top - rect.top
      : height;
    return {
      ok: true,
      width: width,
      height: height,
      baselineFromTop: baselineFromTop
    };
  } catch (error) {
    output.replaceChildren();
    return {
      ok: false,
      error: String(error && error.message ? error.message : error)
    };
  }
};
