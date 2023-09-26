/*
 * Copyright OpenSearch Contributors
 * SPDX-License-Identifier: Apache-2.0
 */

package org.opensearch.sql.spark.client;

import java.util.Map;
import lombok.Data;

@Data
public class StartJobRequest {
  private final String query;
  private final String jobName;
  private final String applicationId;
  private final String executionRoleArn;
  private final String sparkSubmitParams;
  private final Map<String, String> tags;
}
