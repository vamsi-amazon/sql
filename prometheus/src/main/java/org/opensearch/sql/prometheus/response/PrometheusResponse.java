/*
 * Copyright OpenSearch Contributors
 * SPDX-License-Identifier: Apache-2.0
 */

package org.opensearch.sql.prometheus.response;

import static org.opensearch.sql.data.type.ExprCoreType.DOUBLE;
import static org.opensearch.sql.data.type.ExprCoreType.INTEGER;
import static org.opensearch.sql.data.type.ExprCoreType.LONG;
import static org.opensearch.sql.data.type.ExprCoreType.numberTypes;
import static org.opensearch.sql.prometheus.data.constants.PrometheusFieldConstants.LABELS;
import static org.opensearch.sql.prometheus.data.constants.PrometheusFieldConstants.VALUE;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import lombok.NonNull;
import org.json.JSONArray;
import org.json.JSONObject;
import org.opensearch.sql.data.model.ExprDoubleValue;
import org.opensearch.sql.data.model.ExprIntegerValue;
import org.opensearch.sql.data.model.ExprLongValue;
import org.opensearch.sql.data.model.ExprStringValue;
import org.opensearch.sql.data.model.ExprTimestampValue;
import org.opensearch.sql.data.model.ExprTupleValue;
import org.opensearch.sql.data.model.ExprValue;
import org.opensearch.sql.data.type.ExprType;
import org.opensearch.sql.prometheus.storage.model.PrometheusResponseFieldNames;

public class PrometheusResponse implements Iterable<ExprValue> {

  private final JSONObject responseObject;

  private final PrometheusResponseFieldNames prometheusResponseFieldNames;

  private final Boolean isQueryRangeFunctionScan;

  /**
   * Constructor.
   *
   * @param responseObject               Prometheus responseObject.
   * @param prometheusResponseFieldNames data model which
   *                                     contains field names for the metric measurement
   *                                     and timestamp fieldName.
   */
  public PrometheusResponse(JSONObject responseObject,
                            PrometheusResponseFieldNames prometheusResponseFieldNames,
                            Boolean isQueryRangeFunctionScan) {
    this.responseObject = responseObject;
    this.prometheusResponseFieldNames = prometheusResponseFieldNames;
    this.isQueryRangeFunctionScan = isQueryRangeFunctionScan;
  }

  @NonNull
  @Override
  public Iterator<ExprValue> iterator() {
    List<ExprValue> result = new ArrayList<>();
    if ("matrix".equals(responseObject.getString("resultType"))) {
      JSONArray itemArray = responseObject.getJSONArray("result");
      for (int i = 0; i < itemArray.length(); i++) {
        JSONObject item = itemArray.getJSONObject(i);
        JSONObject metric = item.getJSONObject("metric");
        JSONArray values = item.getJSONArray("values");
        for (int j = 0; j < values.length(); j++) {
          LinkedHashMap<String, ExprValue> linkedHashMap = new LinkedHashMap<>();
          JSONArray val = values.getJSONArray(j);
          linkedHashMap.put(prometheusResponseFieldNames.getTimestampFieldName(),
              new ExprTimestampValue(Instant.ofEpochMilli((long) (val.getDouble(0) * 1000))));
          linkedHashMap.put(prometheusResponseFieldNames.getValueFieldName(), getValue(val, 1,
              prometheusResponseFieldNames.getValueType()));
          if (isQueryRangeFunctionScan) {
            linkedHashMap.put(LABELS, new ExprStringValue(metric.toString()));
          } else {
            insertLabels(linkedHashMap, metric);
          }
          result.add(new ExprTupleValue(linkedHashMap));
        }
      }
    } else {
      throw new RuntimeException(String.format("Unexpected Result Type: %s during Prometheus "
              + "Response Parsing. 'matrix' resultType is expected",
          responseObject.getString("resultType")));
    }
    return result.iterator();
  }

  private void insertLabels(LinkedHashMap<String, ExprValue> linkedHashMap, JSONObject metric) {
    for (String key : metric.keySet()) {
      linkedHashMap.put(key, new ExprStringValue(metric.getString(key)));
    }
  }

  private ExprValue getValue(JSONArray jsonArray, Integer index, ExprType exprType) {
    if (INTEGER.equals(exprType)) {
      return new ExprIntegerValue(jsonArray.getInt(index));
    } else if (LONG.equals(exprType)) {
      return new ExprLongValue(jsonArray.getLong(index));
    }
    return new ExprDoubleValue(jsonArray.getDouble(index));
  }

}
