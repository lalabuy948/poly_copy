// Profile Charts - Trade visualization hooks for ProfileLive

// Format timestamp to readable string
function formatTime(timestamp) {
  const date = new Date(timestamp)
  const month = date.toLocaleString('en-US', { month: 'short' })
  const day = date.getDate()
  const hours = date.getHours().toString().padStart(2, '0')
  const mins = date.getMinutes().toString().padStart(2, '0')
  return `${month} ${day} ${hours}:${mins}`
}

// Format number with commas (e.g., 1,234,567.89)
function formatNumber(num, decimals = 2) {
  return num.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals
  })
}

// Format currency with commas
function formatCurrency(num) {
  return '$' + formatNumber(Math.abs(num), 2)
}

// Format shares with suffix (k, M)
function formatShares(num) {
  if (num >= 1000000) return formatNumber(num / 1000000, 1) + 'M'
  if (num >= 1000) return formatNumber(num / 1000, 1) + 'k'
  return formatNumber(num, 1)
}

// Common chart options
const commonOptions = {
  responsive: true,
  maintainAspectRatio: false,
  interaction: {
    mode: 'nearest',
    intersect: false,
  },
  plugins: {
    legend: {
      position: 'top',
      labels: {
        usePointStyle: true,
        padding: 15,
        font: { size: 11 }
      }
    },
    tooltip: {
      backgroundColor: 'rgba(0, 0, 0, 0.8)',
      titleFont: { size: 12 },
      bodyFont: { size: 11 },
      padding: 10,
      cornerRadius: 6,
    }
  },
  scales: {
    x: {
      type: 'linear',
      grid: {
        display: false
      },
      ticks: {
        maxRotation: 45,
        font: { size: 10 },
        callback: function(value) {
          return formatTime(value)
        }
      }
    },
    y: {
      grid: {
        color: 'rgba(128, 128, 128, 0.1)'
      },
      ticks: {
        font: { size: 10 }
      }
    }
  }
}

// Normalize outcome to uppercase for consistent comparison
function normalizeOutcome(outcome) {
  return (outcome || '').toUpperCase()
}

// Normalize side to uppercase for consistent comparison
function normalizeSide(side) {
  return (side || '').toUpperCase()
}

// Downsample data for large datasets to prevent rendering lag
// Takes every Nth point to reduce to target size
function downsample(data, targetSize) {
  if (data.length <= targetSize) return data
  const step = Math.ceil(data.length / targetSize)
  return data.filter((_, i) => i % step === 0)
}

// Trade Dots Chart - Bubble chart of individual trades (size = trade volume)
export const TradeDotsChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    // Destroy existing chart if present
    if (this.chart) {
      this.chart.destroy()
    }

    // Clear any existing canvas
    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    let data = JSON.parse(this.el.dataset.trades || '[]')

    // Handle empty data gracefully
    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No trade data available</div>'
      return
    }

    // Downsample large datasets to prevent rendering lag
    if (data.length > 1000) {
      data = downsample(data, 500)
    }

    // Calculate min/max cost for scaling bubble sizes
    const costs = data.map(t => t.cost).filter(c => c > 0)
    const maxCost = Math.max(...costs, 1)
    const minCost = Math.min(...costs, 0)

    // Scale function for bubble radius (sqrt scale for area perception)
    const getRadius = (cost) => {
      const minRadius = 2
      const maxRadius = 10
      if (maxCost === minCost) return (minRadius + maxRadius) / 2
      const normalized = (cost - minCost) / (maxCost - minCost)
      return minRadius + Math.sqrt(normalized) * (maxRadius - minRadius)
    }

    // Add radius to each point
    const addRadius = (trades) => trades.map(t => ({ ...t, r: getRadius(t.cost) }))

    // Separate YES and NO trades using normalized comparisons
    const yesBuys = addRadius(data.filter(t => normalizeOutcome(t.outcome) === 'YES' && (normalizeSide(t.side) === 'BUY' || normalizeSide(t.side) === 'YES')))
    const yesSells = addRadius(data.filter(t => normalizeOutcome(t.outcome) === 'YES' && (normalizeSide(t.side) === 'SELL' || normalizeSide(t.side) === 'NO')))
    const noBuys = addRadius(data.filter(t => normalizeOutcome(t.outcome) === 'NO' && (normalizeSide(t.side) === 'BUY' || normalizeSide(t.side) === 'YES')))
    const noSells = addRadius(data.filter(t => normalizeOutcome(t.outcome) === 'NO' && (normalizeSide(t.side) === 'SELL' || normalizeSide(t.side) === 'NO')))

    this.chart = new Chart(canvas, {
      type: 'bubble',
      data: {
        datasets: [
          {
            label: 'YES Buy',
            data: yesBuys,
            backgroundColor: 'rgba(34, 197, 94, 0.5)',
            borderColor: 'rgba(34, 197, 94, 0.8)',
            borderWidth: 1,
            hoverBackgroundColor: 'rgba(34, 197, 94, 0.7)',
          },
          {
            label: 'YES Sell',
            data: yesSells,
            backgroundColor: 'rgba(34, 197, 94, 0.2)',
            borderColor: 'rgba(34, 197, 94, 0.5)',
            borderWidth: 1,
            borderDash: [3, 3],
            hoverBackgroundColor: 'rgba(34, 197, 94, 0.4)',
          },
          {
            label: 'NO Buy',
            data: noBuys,
            backgroundColor: 'rgba(239, 68, 68, 0.5)',
            borderColor: 'rgba(239, 68, 68, 0.8)',
            borderWidth: 1,
            hoverBackgroundColor: 'rgba(239, 68, 68, 0.7)',
          },
          {
            label: 'NO Sell',
            data: noSells,
            backgroundColor: 'rgba(239, 68, 68, 0.2)',
            borderColor: 'rgba(239, 68, 68, 0.5)',
            borderWidth: 1,
            borderDash: [3, 3],
            hoverBackgroundColor: 'rgba(239, 68, 68, 0.4)',
          }
        ]
      },
      options: {
        ...commonOptions,
        plugins: {
          ...commonOptions.plugins,
          tooltip: {
            ...commonOptions.plugins.tooltip,
            callbacks: {
              title: (context) => formatTime(context[0].raw.x),
              label: (context) => {
                const p = context.raw
                return [
                  `${p.side} ${p.outcome}`,
                  `Price: ${p.y.toFixed(1)}¢`,
                  `Shares: ${formatShares(p.shares)}`,
                  `Cost: ${formatCurrency(p.cost)}`
                ]
              }
            }
          }
        },
        scales: {
          ...commonOptions.scales,
          y: {
            ...commonOptions.scales.y,
            title: { display: true, text: 'Price (¢)', font: { size: 11 } },
            min: -5,
            max: 105,
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

// Cumulative Shares Chart - Line chart of YES/NO shares over time
export const CumulativeSharesChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy()
    }

    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    let data = JSON.parse(this.el.dataset.cumulative || '[]')

    // Handle empty data gracefully
    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No cumulative share data available</div>'
      return
    }

    // Downsample large datasets
    if (data.length > 1000) {
      data = downsample(data, 500)
    }

    this.chart = new Chart(canvas, {
      type: 'line',
      data: {
        datasets: [
          {
            label: 'YES Shares',
            data: data.map(d => ({ x: d.x, y: d.yes_shares })),
            borderColor: 'rgba(34, 197, 94, 1)',
            backgroundColor: 'rgba(34, 197, 94, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          },
          {
            label: 'NO Shares',
            data: data.map(d => ({ x: d.x, y: d.no_shares })),
            borderColor: 'rgba(239, 68, 68, 1)',
            backgroundColor: 'rgba(239, 68, 68, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          }
        ]
      },
      options: {
        ...commonOptions,
        plugins: {
          ...commonOptions.plugins,
          tooltip: {
            ...commonOptions.plugins.tooltip,
            callbacks: {
              title: (context) => formatTime(context[0].raw.x),
              label: (context) => `${context.dataset.label}: ${formatNumber(context.parsed.y, 1)}`
            }
          }
        },
        scales: {
          ...commonOptions.scales,
          y: {
            ...commonOptions.scales.y,
            title: { display: true, text: 'Shares', font: { size: 11 } },
            beginAtZero: true,
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

// Cumulative Dollars Chart - Line chart of dollars spent on YES/NO
export const CumulativeDollarsChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy()
    }

    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    let data = JSON.parse(this.el.dataset.cumulative || '[]')

    // Handle empty data gracefully
    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No cumulative cost data available</div>'
      return
    }

    // Downsample large datasets
    if (data.length > 1000) {
      data = downsample(data, 500)
    }

    this.chart = new Chart(canvas, {
      type: 'line',
      data: {
        datasets: [
          {
            label: 'YES ($)',
            data: data.map(d => ({ x: d.x, y: d.yes_cost })),
            borderColor: 'rgba(34, 197, 94, 1)',
            backgroundColor: 'rgba(34, 197, 94, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          },
          {
            label: 'NO ($)',
            data: data.map(d => ({ x: d.x, y: d.no_cost })),
            borderColor: 'rgba(239, 68, 68, 1)',
            backgroundColor: 'rgba(239, 68, 68, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          }
        ]
      },
      options: {
        ...commonOptions,
        plugins: {
          ...commonOptions.plugins,
          tooltip: {
            ...commonOptions.plugins.tooltip,
            callbacks: {
              title: (context) => formatTime(context[0].raw.x),
              label: (context) => `${context.dataset.label}: ${formatCurrency(context.parsed.y)}`
            }
          }
        },
        scales: {
          ...commonOptions.scales,
          y: {
            ...commonOptions.scales.y,
            title: { display: true, text: 'Cost ($)', font: { size: 11 } },
            beginAtZero: true,
            ticks: {
              callback: (value) => '$' + formatNumber(value, 0)
            }
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

// Exposure Chart - YES/NO exposure and net position
export const ExposureChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy()
    }

    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    let data = JSON.parse(this.el.dataset.exposure || '[]')

    // Handle empty data gracefully
    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No exposure data available</div>'
      return
    }

    // Downsample large datasets
    if (data.length > 1000) {
      data = downsample(data, 500)
    }

    this.chart = new Chart(canvas, {
      type: 'line',
      data: {
        datasets: [
          {
            label: 'YES Exposure ($)',
            data: data.map(d => ({ x: d.x, y: d.yes_exposure })),
            borderColor: 'rgba(34, 197, 94, 1)',
            backgroundColor: 'transparent',
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          },
          {
            label: 'NO Exposure ($)',
            data: data.map(d => ({ x: d.x, y: d.no_exposure })),
            borderColor: 'rgba(239, 68, 68, 1)',
            backgroundColor: 'transparent',
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
          },
          {
            label: 'Net Exposure ($)',
            data: data.map(d => ({ x: d.x, y: d.net_exposure })),
            borderColor: 'rgba(59, 130, 246, 1)',
            backgroundColor: 'rgba(59, 130, 246, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
            borderWidth: 2,
          }
        ]
      },
      options: {
        ...commonOptions,
        plugins: {
          ...commonOptions.plugins,
          tooltip: {
            ...commonOptions.plugins.tooltip,
            callbacks: {
              title: (context) => formatTime(context[0].raw.x),
              label: (context) => `${context.dataset.label}: ${formatCurrency(context.parsed.y)}`
            }
          }
        },
        scales: {
          ...commonOptions.scales,
          y: {
            ...commonOptions.scales.y,
            title: { display: true, text: 'Exposure ($)', font: { size: 11 } },
            beginAtZero: true,
            ticks: {
              callback: (value) => '$' + formatNumber(value, 0)
            }
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

// PnL Chart - Realized profit/loss over time
export const PnLChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy()
    }

    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    let data = JSON.parse(this.el.dataset.pnl || '[]')

    // Handle empty data gracefully
    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No PnL data available</div>'
      return
    }

    // Downsample large datasets
    if (data.length > 1000) {
      data = downsample(data, 500)
    }

    // Determine if final PnL is positive or negative for coloring
    const finalPnL = data[data.length - 1].realized_pnl
    const isPositive = finalPnL >= 0

    this.chart = new Chart(canvas, {
      type: 'line',
      data: {
        datasets: [
          {
            label: 'Realized PnL ($)',
            data: data.map(d => ({ x: d.x, y: d.realized_pnl })),
            borderColor: isPositive ? 'rgba(34, 197, 94, 1)' : 'rgba(239, 68, 68, 1)',
            backgroundColor: isPositive ? 'rgba(34, 197, 94, 0.1)' : 'rgba(239, 68, 68, 0.1)',
            fill: true,
            tension: 0.1,
            pointRadius: 2,
            pointHoverRadius: 5,
            borderWidth: 2,
          }
        ]
      },
      options: {
        ...commonOptions,
        plugins: {
          ...commonOptions.plugins,
          tooltip: {
            ...commonOptions.plugins.tooltip,
            callbacks: {
              title: (context) => formatTime(context[0].raw.x),
              label: (context) => {
                const val = context.parsed.y
                const sign = val >= 0 ? '+' : '-'
                return `PnL: ${sign}${formatCurrency(val)}`
              }
            }
          }
        },
        scales: {
          ...commonOptions.scales,
          y: {
            ...commonOptions.scales.y,
            title: { display: true, text: 'PnL ($)', font: { size: 11 } },
            ticks: {
              callback: (value) => {
                const sign = value >= 0 ? '+' : '-'
                return sign + '$' + formatNumber(Math.abs(value), 0)
              }
            }
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}

// Color palette for market tags
const tagColors = {
  'Politics': { bg: 'rgba(59, 130, 246, 0.7)', border: 'rgba(59, 130, 246, 1)' },      // Blue
  'Crypto': { bg: 'rgba(245, 158, 11, 0.7)', border: 'rgba(245, 158, 11, 1)' },        // Amber
  'Economy': { bg: 'rgba(16, 185, 129, 0.7)', border: 'rgba(16, 185, 129, 1)' },       // Emerald
  'Sports': { bg: 'rgba(239, 68, 68, 0.7)', border: 'rgba(239, 68, 68, 1)' },          // Red
  'Tech': { bg: 'rgba(139, 92, 246, 0.7)', border: 'rgba(139, 92, 246, 1)' },          // Violet
  'Geopolitics': { bg: 'rgba(236, 72, 153, 0.7)', border: 'rgba(236, 72, 153, 1)' },   // Pink
  'Entertainment': { bg: 'rgba(6, 182, 212, 0.7)', border: 'rgba(6, 182, 212, 1)' },   // Cyan
  'Weather': { bg: 'rgba(34, 197, 94, 0.7)', border: 'rgba(34, 197, 94, 1)' },         // Green
  'Markets': { bg: 'rgba(251, 146, 60, 0.7)', border: 'rgba(251, 146, 60, 1)' },       // Orange
  'Science': { bg: 'rgba(99, 102, 241, 0.7)', border: 'rgba(99, 102, 241, 1)' },       // Indigo
  'Health': { bg: 'rgba(244, 63, 94, 0.7)', border: 'rgba(244, 63, 94, 1)' },          // Rose
  'Legal': { bg: 'rgba(168, 85, 247, 0.7)', border: 'rgba(168, 85, 247, 1)' },         // Purple
  'Regulation': { bg: 'rgba(234, 179, 8, 0.7)', border: 'rgba(234, 179, 8, 1)' },      // Yellow
  'Gaming': { bg: 'rgba(20, 184, 166, 0.7)', border: 'rgba(20, 184, 166, 1)' },        // Teal
  'Other': { bg: 'rgba(156, 163, 175, 0.7)', border: 'rgba(156, 163, 175, 1)' },       // Gray
}

// Market Tags Chart - Doughnut chart of trade distribution by category
export const MarketTagsChart = {
  mounted() {
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (this.chart) {
      this.chart.destroy()
    }

    this.el.innerHTML = ''
    const canvas = document.createElement('canvas')
    this.el.appendChild(canvas)

    const data = JSON.parse(this.el.dataset.tags || '[]')

    if (data.length === 0) {
      this.el.innerHTML = '<div class="flex items-center justify-center h-full text-base-content/50">No data</div>'
      return
    }

    const labels = data.map(d => d.tag)
    const counts = data.map(d => d.count)
    const total = counts.reduce((a, b) => a + b, 0)

    // Map colors to tags
    const backgroundColors = labels.map(label => (tagColors[label] || tagColors['Other']).bg)
    const borderColors = labels.map(label => (tagColors[label] || tagColors['Other']).border)

    // Add counts to labels for display
    const labelsWithCounts = labels.map((label, i) => `${label} (${counts[i]})`)

    this.chart = new Chart(canvas, {
      type: 'doughnut',
      data: {
        labels: labelsWithCounts,
        datasets: [{
          data: counts,
          backgroundColor: backgroundColors,
          borderColor: borderColors,
          borderWidth: 2,
          hoverOffset: 8,
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        cutout: '60%',
        plugins: {
          legend: {
            position: 'right',
            labels: {
              usePointStyle: true,
              pointStyle: 'circle',
              padding: 12,
              font: { size: 11 }
            }
          },
          tooltip: {
            backgroundColor: 'rgba(0, 0, 0, 0.8)',
            titleFont: { size: 12 },
            bodyFont: { size: 11 },
            padding: 10,
            cornerRadius: 6,
            callbacks: {
              title: (context) => labels[context[0].dataIndex],
              label: (context) => {
                const value = context.parsed
                const percentage = ((value / total) * 100).toFixed(1)
                return `${formatNumber(value, 0)} trades (${percentage}%)`
              }
            }
          }
        }
      }
    })
  },

  destroyed() {
    if (this.chart) {
      this.chart.destroy()
    }
  }
}
