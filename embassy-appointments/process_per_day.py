import pandas as pd

# Running with Python virtual environment: 
#
#   python3 -m venv myenv
#   source myenv/bin/activate
#   pip install pandas numpy
#   python3 process_per_day.py 
#   deactivate

# Load data
df = pd.read_csv('available-embassy-appointment-logger.csv', header=None)
df.columns = ['timestamp', 'location', 'nr']

# Parse timestamps and group by day
df['timestamp'] = pd.to_datetime(df['timestamp'])
df['day'] = df['timestamp'].dt.floor('D')   # day bucket (00:00:00)

# For each day+location, take the maximum nr observed that day
df_agg = (
    df.groupby(['day', 'location'], as_index=False)['nr']
      .max()
)

# Pivot: one row per day, one column per location
out = (
    df_agg.pivot(index='day', columns='location', values='nr')
          .fillna(0)          # or leave NaN / use '' if you prefer blank cells
          .reset_index()
)

out.columns.name = None
out = out.rename(columns={'day': 'date'})

# Save to CSV
out.to_csv('output.csv', index=False)