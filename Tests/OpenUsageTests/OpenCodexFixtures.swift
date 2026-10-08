import Foundation

// Trimmed from the redacted hub samples supplied for this provider. No credentials or account IDs.
enum OpenCodexFixtures {
    static let quotas = Data(#"""
{
  "reports": [
    {
      "provider": "openai",
      "quota": {
        "fiveHourPercent": 52,
        "weeklyPercent": 34.38095238095238,
        "updatedAt": 1791284863719
      },
      "aggregation": {
        "currentAccount": {
          "isMain": true,
          "plan": "pro",
          "quota": {
            "weeklyPercent": 34,
            "weeklyResetAt": 1791581420,
            "updatedAt": 1791284896208
          }
        }
      }
    },
    {
      "provider": "anthropic",
      "quota": {
        "fiveHourPercent": 93,
        "fiveHourResetAt": 1791284999839,
        "weeklyPercent": 13,
        "weeklyResetAt": 1791842399839,
        "updatedAt": 1791284951974
      }
    },
    {
      "provider": "xai",
      "quota": {
        "weeklyPercent": 18,
        "weeklyResetAt": 1791390713092,
        "updatedAt": 1791284951854
      }
    },
    {
      "provider": "google-antigravity",
      "quota": {
        "customWindows": [
          {
            "label": "Gem",
            "percent": 3.7477500000000106,
            "resetAt": 1791288414000
          },
          {
            "label": "Gem (Weekly)",
            "percent": 3.9112149999999986,
            "resetAt": 1791487096000
          },
          {
            "label": "Cla",
            "percent": 0,
            "resetAt": 1791302952000
          },
          {
            "label": "Cla (Weekly)",
            "percent": 0,
            "resetAt": 1791889752000
          }
        ],
        "updatedAt": 1791284952109
      }
    },
    {
      "provider": "kiro",
      "quota": {
        "monthlyPercent": 0,
        "kiroCreditsUsed": 0,
        "kiroCreditsLimit": 50,
        "monthlyResetAt": 1793491200000,
        "updatedAt": 1791284952484
      }
    }
  ]
}
"""#.utf8)

    static let usage = Data(#"""
{
  "days": [
    {
      "date": "2026-10-04",
      "totalTokens": 10288188,
      "estimatedCostUsd": 14.868494250000005
    },
    {
      "date": "2026-10-05",
      "totalTokens": 126822541,
      "estimatedCostUsd": 367.54341261999934
    },
    {
      "date": "2026-10-06",
      "totalTokens": 116650385,
      "estimatedCostUsd": 185.00324317
    }
  ]
}
"""#.utf8)
}
