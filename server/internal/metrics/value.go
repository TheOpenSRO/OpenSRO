package metrics

import (
	dto "github.com/prometheus/client_model/go"
)

// Value is the current value of the series name{labels} on Registry (name
// without the "opensro_" prefix for the server's own families, or a full name
// like "go_goroutines"), summed over every series whose labels include the
// given pairs ("dir", "in", ...). A histogram's value is its sample count.
// For tests and the QA scripts' assertions; 0 when nothing matches.
func Value(name string, labelPairs ...string) float64 {
	fams, err := Registry.Gather()
	if err != nil {
		return 0
	}
	want := map[string]string{}
	for i := 0; i+1 < len(labelPairs); i += 2 {
		want[labelPairs[i]] = labelPairs[i+1]
	}
	total := 0.0
	for _, f := range fams {
		if f.GetName() != Namespace+"_"+name && f.GetName() != name {
			continue
		}
		for _, m := range f.GetMetric() {
			if !matches(m, want) {
				continue
			}
			switch {
			case m.Counter != nil:
				total += m.Counter.GetValue()
			case m.Gauge != nil:
				total += m.Gauge.GetValue()
			case m.Histogram != nil:
				total += float64(m.Histogram.GetSampleCount())
			case m.Untyped != nil:
				total += m.Untyped.GetValue()
			}
		}
	}
	return total
}

func matches(m *dto.Metric, want map[string]string) bool {
	got := 0
	for _, lp := range m.GetLabel() {
		if v, ok := want[lp.GetName()]; ok {
			if v != lp.GetValue() {
				return false
			}
			got++
		}
	}
	return got == len(want)
}
