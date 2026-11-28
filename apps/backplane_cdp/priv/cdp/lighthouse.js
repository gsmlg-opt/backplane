async function backplaneLighthouseAudit(options) {
  if (location.protocol !== 'devtools:' || location.host !== 'devtools' || !location.pathname.startsWith('/bundled/')) {
    throw new Error('Untrusted DevTools frontend');
  }
  const SDK = await import('./core/sdk/sdk.js');
  if (SDK.TargetManager.TargetManager.instance().primaryPageTarget()?.id() !== options.targetId) {
    throw new Error('The DevTools frontend is attached to another page');
  }
  const modules = await import('./panels/lighthouse/lighthouse.js');
  const service = new modules.LighthouseProtocolService.ProtocolService();
  const runs = globalThis.__backplaneLighthouseRuns ??= new Map();
  let stopping;
  const stop = () => stopping ??= service.detach();
  runs.set(options.token, {stop});
  try {
    await service.attach(options.url);
    const mobile = options.device === 'mobile';
    const categories = ['accessibility', 'seo', 'best-practices', 'agentic-browsing'];
    const flags = {
      mode: options.mode,
      formFactor: options.device,
      onlyCategories: categories,
      output: ['json'],
      maxWaitForLoad: 30000,
      screenEmulation: {
        mobile,
        width: mobile ? 412 : 1350,
        height: mobile ? 823 : 940,
        deviceScaleFactor: mobile ? 1.75 : 1,
        disabled: false,
      },
      emulatedUserAgent: mobile
        ? 'Mozilla/5.0 (Linux; Android 11; moto g power (2022)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36'
        : 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
    };
    const result = await service.collectLighthouseResults({
      inspectedURL: options.url,
      categoryIDs: categories,
      flags,
    });
    if (!result || result.fatal) {
      throw new Error(result?.message ?? 'Lighthouse audit failed.');
    }
    const lhr = result.lhr;
    return {
      lhr,
      html: Lighthouse.ReportGenerator.ReportGenerator.generateReportHtml(lhr),
      failedAudits: failingAudits(lhr),
      summary: {
        mode: options.mode,
        device: options.device,
        url: lhr.finalDisplayedUrl,
        scores: Object.values(lhr.categories).map(({id, title, score}) => ({id, title, score})),
        audits: {
          failed: Object.values(lhr.audits).filter(audit => audit.score !== null && audit.score < 1).length,
          passed: Object.values(lhr.audits).filter(audit => audit.score === 1).length,
        },
        timing: {total: lhr.timing.total},
      },
    };
  } finally {
    try {
      await stop();
    } finally {
      runs.delete(options.token);
    }
  }

  function failingAudits(lhr) {
    const membership = new Map();
    for (const category of Object.values(lhr.categories)) {
      for (const audit of category.auditRefs) {
        const categories = membership.get(audit.id) ?? [];
        categories.push(category.id);
        membership.set(audit.id, categories);
      }
    }
    return Object.values(lhr.audits)
      .filter(audit => audit.score !== null && audit.score < 1)
      .map(audit => {
        const nodes = new Map();
        collectNodes(audit.details, nodes);
        return {
          id: audit.id,
          title: audit.title,
          description: audit.description,
          score: audit.score,
          categories: membership.get(audit.id) ?? [],
          displayValue: audit.displayValue,
          nodes: [...nodes.values()].slice(0, 10),
          totalNodes: nodes.size,
        };
      });
  }

  function collectNodes(value, nodes) {
    if (Array.isArray(value)) {
      for (const child of value) collectNodes(child, nodes);
      return;
    }
    if (!value || typeof value !== 'object' || value.type === 'debugdata' || value.type === 'subitems') {
      return;
    }
    if (value.type === 'node') {
      const key = value.lhId ?? value.path ??
        ((value.selector || value.snippet) ? `${value.selector ?? ''}|${value.snippet ?? ''}` : nodes.size);
      const node = {};
      for (const field of ['selector', 'snippet', 'nodeLabel', 'explanation']) {
        if (typeof value[field] === 'string' && value[field]) node[field] = value[field];
      }
      nodes.set(key, {...node, ...nodes.get(key)});
      return;
    }
    for (const [name, child] of Object.entries(value)) {
      if (name !== 'subItems') collectNodes(child, nodes);
    }
  }
}
