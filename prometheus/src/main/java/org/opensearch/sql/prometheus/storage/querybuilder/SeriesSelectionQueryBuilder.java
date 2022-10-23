/*
 *
 *  * Copyright OpenSearch Contributors
 *  * SPDX-License-Identifier: Apache-2.0
 *
 */

package org.opensearch.sql.prometheus.storage.querybuilder;


import static org.opensearch.sql.prometheus.data.constants.PrometheusFieldConstants.TIMESTAMP;

import java.util.stream.Collectors;
import org.apache.commons.lang3.StringUtils;
import org.opensearch.sql.expression.Expression;
import org.opensearch.sql.expression.ExpressionNodeVisitor;
import org.opensearch.sql.expression.FunctionExpression;
import org.opensearch.sql.expression.ReferenceExpression;

public class SeriesSelectionQueryBuilder extends ExpressionNodeVisitor<String, Object> {


  /**
   * Build Prometheus series selector query from expression.
   *
   * @param filterCondition expression.
   * @return query string
   */
  public String build(String metricName, Expression filterCondition) {
    if (filterCondition != null) {
      String selectorQuery = filterCondition.accept(this, null);
      return metricName + "{" + selectorQuery + "}";
    }
    return metricName;
  }

  @Override
  public String visitFunction(FunctionExpression func, Object context) {
    if (func.getFunctionName().getFunctionName().equals("and")) {
      return func.getArguments().stream()
          .map(arg -> visitFunction((FunctionExpression) arg, context))
          .filter(StringUtils::isNotEmpty)
          .collect(Collectors.joining(" , "));
    } else if (func.getFunctionName().getFunctionName().contains("=")) {
      ReferenceExpression ref = (ReferenceExpression) func.getArguments().get(0);
      if (!ref.getAttr().equals(TIMESTAMP)) {
        return func.getArguments().get(0)
            + func.getFunctionName().getFunctionName()
            + func.getArguments().get(1);
      } else {
        return null;
      }
    } else {
      throw new RuntimeException(
          String.format("Prometheus Catalog doesn't support %s in where command.",
              func.getFunctionName().getFunctionName()));
    }
  }

}
