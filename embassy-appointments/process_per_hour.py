import pandas as pd

# Load data
df = pd.read_csv('available-embassy-appointment-logger.csv', header=None)
df.columns = ['timestamp', 'location', 'nr']

# Round timestamp to the nearest hour
df['timestamp'] = pd.to_datetime(df['timestamp']).dt.round('h')

# If there are multiple entries for the same timestamp+location, combine them first
# (use sum/max/first depending on what "nr" means)
df_agg = (
    df.groupby(['timestamp', 'location'], as_index=False)['nr']
      .sum()
)

# Pivot: one row per timestamp, one column per location
out = (
    df_agg.pivot(index='timestamp', columns='location', values='nr')
          .fillna(0)                 # or leave as NaN if you prefer
          .reset_index()
)

# Optional: remove the columns index name ("location") from the header output
out.columns.name = None

# Save to CSV
out.to_csv('output.csv', index=False)